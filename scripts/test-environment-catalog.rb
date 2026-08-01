#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require_relative "environment_catalog"

def assert(condition, message)
  raise message unless condition
end

def assert_catalog_error(message)
  yield
rescue EnvironmentCatalog::CatalogError
  return
end

def write_catalog(directory, content)
  path = File.join(directory, "environment.yaml")
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
      terraform/admin/airflow-k8s: admin/airflow-k8s/
      terraform/admin/argo-rollouts-k8s: admin/argo-rollouts-k8s/
      terraform/admin/argocd-k8s: admin/argocd-k8s/
      terraform/admin/autoresearch-k8s: admin/autoresearch-k8s/
      terraform/admin/elastic-k8s: admin/elastic-k8s/
      terraform/admin/gke-team-access: admin/gke-team-access/
      terraform/admin/mlflow-k8s: admin/mlflow-k8s/
      terraform/admin/monitoring-k8s: admin/monitoring-k8s/
      terraform/admin/vault-k8s: admin/vault-k8s/
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
    VALID_CATALOG.sub("    project_id: autoresearch-503903\n", "")
  )
  assert_catalog_error("project_id 누락을 허용하면 안 됩니다") do
    EnvironmentCatalog.load(missing_project_path).validate!
  end

  assert_catalog_error("알려지지 않은 Terraform root의 backend를 만들면 안 됩니다") do
    catalog.backend_config("terraform/admin/unknown-root")
  end

  Dir.mktmpdir("environment-catalog-generated-") do |output_root|
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

  init_without_backend = run_wrapper([
    "--environment", "dev", "--root", "terraform/envs/dev", "init", "-backend=false", "-input=false"
  ])
  assert(init_without_backend.include?("init"), "init 명령을 Terraform에 전달해야 합니다")
  assert(!init_without_backend.any? { |argument| argument.start_with?("-backend-config=") }, "-backend=false에는 backend-config를 전달하면 안 됩니다")

  bootstrap_validate = run_wrapper([
    "--environment", "dev", "--root", "terraform/bootstrap", "validate"
  ])
  assert(bootstrap_validate.include?("validate"), "bootstrap validate 명령을 Terraform에 전달해야 합니다")
  assert(!bootstrap_validate.any? { |argument| argument.start_with?("-backend-config=") }, "bootstrap root에는 backend-config를 전달하면 안 됩니다")
end

puts "환경 카탈로그 검증 테스트: 통과"
