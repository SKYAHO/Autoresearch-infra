#!/usr/bin/env ruby
# frozen_string_literal: true

require "ipaddr"
require "json"
require "optparse"
require "yaml"

class EnvironmentCatalog
  class CatalogError < StandardError; end

  # terraform/bootstrap은 의도적으로 제외한다(#413). state 버킷 이름은 전역
  # 유니크라 프로젝트를 넘나드는 안전한 기본값이 없어 default 없는 필수 변수로
  # 두었고, bootstrap을 실행하는 유일한 시나리오가 "새 프로젝트 구축/이전"이다.
  # 여기서 현재 dev 카탈로그 값을 자동 공급하면 -var-file을 깜빡한 운영자가
  # **옛 프로젝트 좌표로 조용히 진행**하게 되어 그 보호가 사라진다.
  TERRAFORM_ROOTS = %w[
    terraform/envs/dev
    terraform/admin/airflow-k8s
    terraform/admin/argo-rollouts-k8s
    terraform/admin/argocd-k8s
    terraform/admin/autoresearch-k8s
    terraform/admin/elastic-k8s
    terraform/admin/gke-team-access
    terraform/admin/mlflow-k8s
    terraform/admin/monitoring-k8s
  ].freeze

  BACKEND_ROOTS = TERRAFORM_ROOTS

  ROOT_VARIABLE_KEYS = {
    "terraform/envs/dev" => %w[
      project_id region zone environment name_prefix dev_subnet_cidr private_services_cidr redis_psc_subnet_cidr
      gke_master_ipv4_cidr gke_pods_cidr gke_services_cidr
    ],
    "terraform/admin/airflow-k8s" => %w[project_id region zone gke_cluster_name resource_prefix private_services_cidr cluster_services_cidr redis_psc_subnet_cidr],
    "terraform/admin/argo-rollouts-k8s" => %w[project_id region zone gke_cluster_name cluster_services_cidr cluster_master_cidr],
    "terraform/admin/argocd-k8s" => %w[project_id region zone gke_cluster_name cluster_services_cidr],
    "terraform/admin/autoresearch-k8s" => %w[project_id region zone gke_cluster_name resource_prefix private_services_cidr cluster_services_cidr redis_psc_subnet_cidr],
    "terraform/admin/elastic-k8s" => %w[project_id region zone gke_cluster_name cluster_services_cidr cluster_master_cidr kibana_ingress_source_cidr],
    "terraform/admin/gke-team-access" => %w[project_id region name_prefix],
    "terraform/admin/mlflow-k8s" => %w[project_id region zone gke_cluster_name resource_prefix private_services_cidr cluster_services_cidr],
    "terraform/admin/monitoring-k8s" => %w[project_id region zone gke_cluster_name]
  }.freeze

  attr_reader :data

  def self.load(path)
    parsed = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    new(parsed)
  rescue Errno::ENOENT, Psych::Exception => error
    raise CatalogError, "환경 카탈로그를 읽을 수 없습니다: #{error.message}"
  end

  def initialize(data)
    @data = data
  end

  def validate!
    raise CatalogError, "카탈로그 최상위 값은 mapping이어야 합니다" unless data.is_a?(Hash)
    raise CatalogError, "schema_version은 1이어야 합니다" unless data["schema_version"] == 1
    raise CatalogError, "environment는 dev여야 합니다" unless data["environment"] == "dev"

    validate_gcp!
    validate_network!
    validate_gke!
    validate_state!
    self
  end

  def terraform_variables(root)
    validate!
    ensure_known_root!(root)

    values = {
      "project_id" => gcp.fetch("project_id"),
      "region" => gcp.fetch("region"),
      "zone" => gcp.fetch("zone"),
      "environment" => data.fetch("environment"),
      "name_prefix" => gcp.fetch("name_prefix"),
      "resource_prefix" => gcp.fetch("resource_prefix"),
      "dev_subnet_cidr" => network.fetch("dev_subnet_cidr"),
      "private_services_cidr" => network.fetch("private_services_cidr"),
      "redis_psc_subnet_cidr" => network.fetch("redis_psc_subnet_cidr"),
      "gke_cluster_name" => gke.fetch("cluster_name"),
      "gke_master_ipv4_cidr" => gke.fetch("master_ipv4_cidr"),
      "gke_pods_cidr" => gke.fetch("pods_cidr"),
      "gke_services_cidr" => gke.fetch("services_cidr"),
      "cluster_master_cidr" => gke.fetch("master_ipv4_cidr"),
      "cluster_services_cidr" => gke.fetch("services_cidr"),
      # port-forward 트래픽이 노드 IP에서 출발하므로 dev subnet이 정본이다(#116).
      # 소비자는 elastic-k8s다.
      "kibana_ingress_source_cidr" => network.fetch("dev_subnet_cidr")
    }
    values.slice(*ROOT_VARIABLE_KEYS.fetch(root))
  end

  def backend_config(root)
    validate!
    raise CatalogError, "backend가 없는 Terraform root입니다: #{root}" unless BACKEND_ROOTS.include?(root)

    {
      "bucket" => state.fetch("bucket"),
      "prefix" => state.fetch("roots").fetch(root)
    }
  end

  def field_value(path)
    validate!
    unless path.is_a?(String) && path.match?(%r{\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*\z})
      raise CatalogError, "카탈로그 필드 경로 형식이 잘못되었습니다"
    end

    path.split(".").reduce(data) do |value, key|
      unless value.is_a?(Hash) && value.key?(key)
        raise CatalogError, "카탈로그 필드를 찾을 수 없습니다: #{path}"
      end

      value.fetch(key)
    end
  end

  def write_terraform_inputs!(root:, output_root:)
    variables = terraform_variables(root)
    backend = backend_config(root) if BACKEND_ROOTS.include?(root)
    target_directory = File.join(output_root, root)
    # root 디렉터리가 없으면 즉시 실패한다(claude-review 14차 지적) — 이
    # 디렉터리는 항상 커밋된 .tf 코드와 함께 존재해야 하므로, 여기서
    # mkdir_p로 조용히 새로 만들면 코드 없이 입력 파일만 있는 사용
    # 불가능한 디렉터리가 생긴다(카탈로그 항목은 있는데 root 디렉터리만
    # 삭제된 경우를 방지, #478 vault-k8s가 과거 실례였다).
    unless Dir.exist?(target_directory)
      raise CatalogError, "Terraform root 디렉터리가 없습니다: #{target_directory}"
    end

    var_file = File.join(target_directory, ".environment.auto.tfvars.json")
    File.write(var_file, JSON.pretty_generate(variables) + "\n")
    backend_file = nil
    if backend
      backend_file = File.join(target_directory, ".environment.backend.hcl")
      File.write(
        backend_file,
        "bucket = #{backend.fetch("bucket").inspect}\n" +
        "prefix = #{backend.fetch("prefix").inspect}\n"
      )
    end

    { var_file: var_file, backend_file: backend_file }
  end

  private

  def gcp
    data.fetch("gcp")
  rescue KeyError
    raise CatalogError, "gcp mapping이 필요합니다"
  end

  def network
    data.fetch("network")
  rescue KeyError
    raise CatalogError, "network mapping이 필요합니다"
  end

  def state
    data.fetch("state")
  rescue KeyError
    raise CatalogError, "state mapping이 필요합니다"
  end

  def gke
    data.fetch("gke")
  rescue KeyError
    raise CatalogError, "gke mapping이 필요합니다"
  end

  def validate_gcp!
    raise CatalogError, "gcp는 mapping이어야 합니다" unless gcp.is_a?(Hash)

    project_id = required_string(gcp, "project_id")
    region = required_string(gcp, "region")
    zone = required_string(gcp, "zone")
    name_prefix = required_string(gcp, "name_prefix")
    resource_prefix = required_string(gcp, "resource_prefix")

    raise CatalogError, "project_id 형식이 잘못되었습니다" unless project_id.match?(/\A[a-z][a-z0-9-]{4,28}[a-z0-9]\z/)
    raise CatalogError, "region 형식이 잘못되었습니다" unless region.match?(/\A[a-z]+-[a-z]+\d+\z/)
    raise CatalogError, "zone은 region에 속해야 합니다" unless zone.start_with?("#{region}-")
    raise CatalogError, "name_prefix 형식이 잘못되었습니다" unless name_prefix.match?(/\A[a-z][a-z0-9-]{2,30}\z/)
    raise CatalogError, "resource_prefix 형식이 잘못되었습니다" unless resource_prefix.match?(/\A[a-z][a-z0-9-]{2,50}\z/)
  end

  def validate_network!
    raise CatalogError, "network는 mapping이어야 합니다" unless network.is_a?(Hash)

    %w[dev_subnet_cidr private_services_cidr redis_psc_subnet_cidr].each do |key|
      IPAddr.new(required_string(network, key))
    rescue IPAddr::InvalidAddressError
      raise CatalogError, "#{key}는 유효한 CIDR이어야 합니다"
    end
  end

  def validate_gke!
    raise CatalogError, "gke는 mapping이어야 합니다" unless gke.is_a?(Hash)

    cluster_name = required_string(gke, "cluster_name")
    raise CatalogError, "gke cluster_name 형식이 잘못되었습니다" unless cluster_name.match?(/\A[a-z][a-z0-9-]{0,38}[a-z0-9]\z/)

    %w[master_ipv4_cidr pods_cidr services_cidr].each do |key|
      IPAddr.new(required_string(gke, key))
    rescue IPAddr::InvalidAddressError
      raise CatalogError, "gke #{key}는 유효한 CIDR이어야 합니다"
    end
  end

  def validate_state!
    raise CatalogError, "state는 mapping이어야 합니다" unless state.is_a?(Hash)

    bucket = required_string(state, "bucket")
    raise CatalogError, "state bucket 형식이 잘못되었습니다" unless bucket.match?(/\A[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]\z/)

    roots = state.fetch("roots") { raise CatalogError, "state.roots mapping이 필요합니다" }
    raise CatalogError, "state.roots는 mapping이어야 합니다" unless roots.is_a?(Hash)

    BACKEND_ROOTS.each do |root|
      prefix = roots[root]
      raise CatalogError, "#{root}의 state prefix가 필요합니다" unless prefix.is_a?(String) && prefix.match?(%r{\A(?:[a-z0-9-]+/)+\z})
    end
  end

  def ensure_known_root!(root)
    raise CatalogError, "지원하지 않는 Terraform root입니다: #{root}" unless TERRAFORM_ROOTS.include?(root)
  end


  def required_string(mapping, key)
    value = mapping[key]
    raise CatalogError, "#{key}는 비어 있지 않은 문자열이어야 합니다" unless value.is_a?(String) && !value.empty?

    value
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = {}
    OptionParser.new do |parser|
      parser.on("--catalog PATH") { |value| options[:catalog] = value }
      parser.on("--root PATH") { |value| options[:root] = value }
      parser.on("--output-root PATH") { |value| options[:output_root] = value }
      parser.on("--field PATH") { |value| options[:field] = value }
    end.parse!

    abort("catalog 인수가 필요합니다") unless options[:catalog]
    catalog = EnvironmentCatalog.load(options[:catalog])
    if options[:field]
      abort("field 조회에는 root 또는 output-root를 함께 사용할 수 없습니다") if options[:root] || options[:output_root]

      value = catalog.field_value(options[:field])
      raise EnvironmentCatalog::CatalogError, "카탈로그 필드 값은 문자열이어야 합니다" unless value.is_a?(String)

      puts value
    else
      %i[root output_root].each do |key|
        abort("#{key} 인수가 필요합니다") unless options[key]
      end

      generated = catalog.write_terraform_inputs!(
        root: options[:root],
        output_root: options[:output_root]
      )
      puts JSON.generate(generated)
    end
  rescue EnvironmentCatalog::CatalogError => error
    warn "환경 카탈로그 오류: #{error.message}"
    exit 1
  end
end
