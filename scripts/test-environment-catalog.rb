#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

require_relative "environment_catalog"

def assert(condition, message)
  raise message unless condition
end

def assert_catalog_error(message)
  yield
  # 블록이 CatalogError를 던지지 않고 끝나면 그 자체가 실패다 — raise가 없으면
  # 모든 음성 테스트가 항진(vacuous) 통과한다.
  raise message
rescue EnvironmentCatalog::CatalogError
  nil
end

def write_catalog(directory, content)
  # 케이스마다 고유 파일을 쓴다 — 같은 이름을 덮어쓰면 앞서 얻은 경로가
  # 뒤의 mutation 내용을 가리키게 되어 테스트끼리 오염된다.
  @catalog_sequence = (@catalog_sequence || 0) + 1
  path = File.join(directory, "environment-#{@catalog_sequence}.yaml")
  File.write(path, content)
  path
end

def run_wrapper(arguments)
  repository_root = File.expand_path("..", __dir__)
  Dir.mktmpdir("environment-catalog-terraform-") do |directory|
    fake_terraform = File.join(directory, "terraform")
    log_path = File.join(directory, "terraform.log")
    File.write(fake_terraform, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ENV_LOG\"\n")
    FileUtils.chmod("u+x", fake_terraform)

    original_path = ENV.fetch("PATH")
    ENV["PATH"] = "#{directory}:#{original_path}"
    ENV["ENV_LOG"] = log_path
    success = system(File.join(repository_root, "scripts", "terraform-env"), *arguments)
    assert(success, "terraform-env 실행이 실패했습니다")
    File.readlines(log_path, chomp: true)
  ensure
    ENV["PATH"] = original_path if original_path
    ENV.delete("ENV_LOG")
    Dir.glob(File.join(repository_root, "terraform", "**", ".environment.*")).each { |path| File.delete(path) }
  end
end

def run_catalog_cli(arguments)
  repository_root = File.expand_path("..", __dir__)
  Open3.capture3("ruby", File.join(repository_root, "scripts", "environment_catalog.rb"), *arguments)
end

VALID_CATALOG = <<~YAML.freeze
  schema_version: 1
  environment: dev
  gcp:
    project_id: autoresearch-503903
    region: asia-northeast3
    zone: asia-northeast3-a
    name_prefix: autoresearch
    resource_prefix: autoresearch-dev
  gke:
    cluster_name: autoresearch-dev-gke
    master_ipv4_cidr: 172.16.0.0/28
    pods_cidr: 172.16.64.0/20
    services_cidr: 172.16.128.0/24
  network:
    dev_subnet_cidr: 10.10.0.0/20
    private_services_cidr: 192.168.0.0/20
    redis_psc_subnet_cidr: 10.10.16.0/29
  state:
    bucket: autoresearch-503903-dev-tfstate
    roots:
      terraform/envs/dev: dev/
      terraform/admin/actions-runner-k8s: admin/actions-runner-k8s/
      terraform/admin/airflow-k8s: admin/airflow-k8s/
      terraform/admin/argo-rollouts-k8s: admin/argo-rollouts-k8s/
      terraform/admin/argocd-k8s: admin/argocd-k8s/
      terraform/admin/autoresearch-k8s: admin/autoresearch-k8s/
      terraform/admin/elastic-k8s: admin/elastic-k8s/
      terraform/admin/gke-team-access: admin/gke-team-access/
      terraform/admin/mlflow-k8s: admin/mlflow-k8s/
      terraform/admin/monitoring-k8s: admin/monitoring-k8s/
YAML

Dir.mktmpdir("environment-catalog-test-") do |directory|
  valid_path = write_catalog(directory, VALID_CATALOG)
  catalog = EnvironmentCatalog.load(valid_path)
  catalog.validate!

  variables = catalog.terraform_variables("terraform/envs/dev")
  assert(variables.fetch("project_id") == "autoresearch-503903", "project_id를 Terraform 입력으로 내보내야 합니다")
  assert(variables.fetch("region") == "asia-northeast3", "region을 Terraform 입력으로 내보내야 합니다")
  assert(variables.fetch("zone") == "asia-northeast3-a", "zone을 Terraform 입력으로 내보내야 합니다")

  airflow_variables = catalog.terraform_variables("terraform/admin/airflow-k8s")
  assert(
    airflow_variables.keys.sort == %w[cluster_services_cidr gke_cluster_name private_services_cidr project_id redis_psc_subnet_cidr region resource_prefix zone],
    "admin root에는 선언된 좌표 변수만 전달해야 합니다"
  )

  mismatched_zone_path = write_catalog(
    directory,
    VALID_CATALOG.sub("zone: asia-northeast3-a", "zone: us-central1-a")
  )
  assert_catalog_error("region과 다른 zone을 허용하면 안 됩니다") do
    EnvironmentCatalog.load(mismatched_zone_path).validate!
  end

  missing_project_path = write_catalog(
    directory,
    VALID_CATALOG.sub(/^ *project_id: autoresearch-503903\n/, "")
  )
  assert_catalog_error("project_id 누락을 허용하면 안 됩니다") do
    EnvironmentCatalog.load(missing_project_path).validate!
  end

  assert_catalog_error("알려지지 않은 Terraform root의 backend를 만들면 안 됩니다") do
    catalog.backend_config("terraform/admin/unknown-root")
  end

  invalid_gke_cidr_path = write_catalog(
    directory,
    VALID_CATALOG.sub("pods_cidr: 172.16.64.0/20", "pods_cidr: not-a-cidr")
  )
  assert_catalog_error("gke CIDR 형식 오류를 허용하면 안 됩니다") do
    EnvironmentCatalog.load(invalid_gke_cidr_path).validate!
  end

  missing_gke_path = write_catalog(
    directory,
    VALID_CATALOG.sub(/^gke:\n(?:  .+\n)+/, "")
  )
  assert_catalog_error("gke mapping 누락을 허용하면 안 됩니다") do
    EnvironmentCatalog.load(missing_gke_path).validate!
  end

  stdout, stderr, status = run_catalog_cli([
    "--catalog", valid_path, "--field", "gcp.project_id"
  ])
  assert(status.success?, "카탈로그 필드 조회가 실패했습니다: #{stderr}")
  assert(stdout == "autoresearch-503903\n", "카탈로그 project_id 조회값이 다릅니다")

  _stdout, stderr, status = run_catalog_cli([
    "--catalog", valid_path, "--field", "gcp.unknown"
  ])
  assert(!status.success?, "존재하지 않는 카탈로그 필드를 허용하면 안 됩니다")
  assert(stderr.include?("환경 카탈로그 오류"), "카탈로그 필드 오류를 안전하게 보고해야 합니다")

  Dir.mktmpdir("environment-catalog-generated-") do |output_root|
    # write_terraform_inputs!는 root 디렉터리가 이미 존재해야 한다(실제
    # 저장소에서는 커밋된 .tf 코드와 함께 항상 존재 — claude-review 14차
    # 지적으로 없으면 CatalogError). 여기 output_root는 합성 tmp dir이라
    # 그 불변조건을 직접 재현해 준다.
    FileUtils.mkdir_p(File.join(output_root, "terraform/envs/dev"))
    generated = catalog.write_terraform_inputs!(
      root: "terraform/envs/dev",
      output_root: output_root
    )
    variables = JSON.parse(File.read(generated.fetch(:var_file)))
    backend = File.read(generated.fetch(:backend_file))

    assert(variables.fetch("project_id") == "autoresearch-503903", "생성 var-file의 project_id가 다릅니다")
    assert(backend.include?("bucket = \"autoresearch-503903-dev-tfstate\""), "생성 backend의 bucket이 다릅니다")
    assert(backend.include?("prefix = \"dev/\""), "생성 backend의 prefix가 다릅니다")
  end

  Dir.mktmpdir("environment-catalog-missing-root-") do |output_root|
    assert_catalog_error("root 디렉터리가 없으면 조용히 만들지 말고 실패해야 합니다") do
      catalog.write_terraform_inputs!(root: "terraform/envs/dev", output_root: output_root)
    end
  end

  init_without_backend = run_wrapper([
    "--environment", "dev", "--root", "terraform/envs/dev", "init", "-backend=false", "-input=false"
  ])
  assert(init_without_backend.include?("init"), "init 명령을 Terraform에 전달해야 합니다")
  assert(!init_without_backend.any? { |argument| argument.start_with?("-backend-config=") }, "-backend=false에는 backend-config를 전달하면 안 됩니다")

  # drift/plan workflow가 실제로 쓰는 호출 형태. backend를 쓰는 root에서
  # -backend=false 없이 init하면 -backend-config가 붙어야 하며, set -e 아래에서
  # 스크립트가 중간에 죽지 않고 이 경로까지 도달하는지도 함께 보장한다.
  init_with_backend = run_wrapper([
    "--environment", "dev", "--root", "terraform/envs/dev", "init", "-reconfigure", "-no-color"
  ])
  assert(init_with_backend.include?("init"), "init 명령을 Terraform에 전달해야 합니다")
  assert(
    init_with_backend.any? { |argument| argument.start_with?("-backend-config=") },
    "backend root의 init에는 -backend-config를 전달해야 합니다"
  )
  assert(init_with_backend.include?("-reconfigure"), "사용자 인수(-reconfigure)를 그대로 전달해야 합니다")

  # #413 보호: bootstrap은 카탈로그 공급 대상이 아니어야 한다. 현재 dev 좌표를
  # 자동 주입하면 새 프로젝트 구축 시 옛 버킷명으로 조용히 진행될 수 있다.
  assert_catalog_error("bootstrap root에 카탈로그 변수를 공급하면 안 됩니다") do
    catalog.terraform_variables("terraform/bootstrap")
  end

  # root마다 서로 다른 state prefix를 받아야 한다. 각 versions.tf에서 prefix를
  # 지웠으므로, 여기서 어긋나면 두 root가 같은 state를 덮어쓰는 사고가 된다.
  seen_prefixes = {}
  EnvironmentCatalog::BACKEND_ROOTS.each do |backend_root|
    config = catalog.backend_config(backend_root)
    assert(
      config.fetch("bucket") == "autoresearch-503903-dev-tfstate",
      "#{backend_root}의 backend bucket이 카탈로그와 다릅니다"
    )
    prefix = config.fetch("prefix")
    assert(!prefix.to_s.empty?, "#{backend_root}의 state prefix가 비어 있습니다")
    assert(
      !seen_prefixes.key?(prefix),
      "state prefix가 중복됩니다: #{prefix} (#{seen_prefixes[prefix]} ↔ #{backend_root})"
    )
    seen_prefixes[prefix] = backend_root
  end
  assert(
    seen_prefixes.size == EnvironmentCatalog::BACKEND_ROOTS.size,
    "backend root 수와 고유 prefix 수가 다릅니다"
  )
end

puts "환경 카탈로그 검증 테스트: 통과"
