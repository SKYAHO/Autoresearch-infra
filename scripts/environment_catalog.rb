#!/usr/bin/env ruby
# frozen_string_literal: true

require "ipaddr"
require "fileutils"
require "json"
require "optparse"
require "yaml"

class EnvironmentCatalog
  class CatalogError < StandardError; end

  TERRAFORM_ROOTS = %w[
    terraform/bootstrap
    terraform/envs/dev
    terraform/admin/airflow-k8s
    terraform/admin/argo-rollouts-k8s
    terraform/admin/argocd-k8s
    terraform/admin/autoresearch-k8s
    terraform/admin/elastic-k8s
    terraform/admin/gke-team-access
    terraform/admin/mlflow-k8s
    terraform/admin/monitoring-k8s
    terraform/admin/vault-k8s
  ].freeze

  BACKEND_ROOTS = TERRAFORM_ROOTS - ["terraform/bootstrap"]

  ROOT_VARIABLE_KEYS = {
    "terraform/envs/dev" => %w[
      project_id region zone environment name_prefix dev_subnet_cidr private_services_cidr redis_psc_subnet_cidr
      gke_master_ipv4_cidr gke_pods_cidr gke_services_cidr
    ],
    "terraform/admin/airflow-k8s" => %w[project_id region zone gke_cluster_name resource_prefix private_services_cidr cluster_services_cidr redis_psc_subnet_cidr],
    "terraform/admin/argo-rollouts-k8s" => %w[project_id region zone gke_cluster_name cluster_services_cidr cluster_master_cidr],
    "terraform/admin/argocd-k8s" => %w[project_id region zone gke_cluster_name cluster_services_cidr],
    "terraform/admin/autoresearch-k8s" => %w[project_id region zone gke_cluster_name resource_prefix private_services_cidr cluster_services_cidr redis_psc_subnet_cidr],
    "terraform/admin/elastic-k8s" => %w[project_id region zone gke_cluster_name cluster_services_cidr cluster_master_cidr],
    "terraform/admin/gke-team-access" => %w[project_id region name_prefix],
    "terraform/admin/mlflow-k8s" => %w[project_id region zone gke_cluster_name resource_prefix private_services_cidr cluster_services_cidr],
    "terraform/admin/monitoring-k8s" => %w[project_id region zone gke_cluster_name],
    "terraform/admin/vault-k8s" => %w[project_id region zone gke_cluster_name ui_ingress_source_cidr cluster_services_cidr cluster_master_cidr]
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
    validate_state!
    self
  end

  def terraform_variables(root)
    validate!
    ensure_known_root!(root)

    return bootstrap_variables if root == "terraform/bootstrap"

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
      "gke_cluster_name" => data.fetch("gke").fetch("cluster_name"),
      "gke_master_ipv4_cidr" => data.fetch("gke").fetch("master_ipv4_cidr"),
      "gke_pods_cidr" => data.fetch("gke").fetch("pods_cidr"),
      "gke_services_cidr" => data.fetch("gke").fetch("services_cidr"),
      "cluster_master_cidr" => data.fetch("gke").fetch("master_ipv4_cidr"),
      "cluster_services_cidr" => data.fetch("gke").fetch("services_cidr"),
      "ui_ingress_source_cidr" => network.fetch("dev_subnet_cidr")
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

  def write_terraform_inputs!(root:, output_root:)
    variables = terraform_variables(root)
    backend = backend_config(root) if BACKEND_ROOTS.include?(root)
    target_directory = File.join(output_root, root)
    FileUtils.mkdir_p(target_directory)

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

  def validate_gcp!
    raise CatalogError, "gcp는 mapping이어야 합니다" unless gcp.is_a?(Hash)

    project_id = required_string(gcp, "project_id")
    region = required_string(gcp, "region")
    zone = required_string(gcp, "zone")
    name_prefix = required_string(gcp, "name_prefix")

    raise CatalogError, "project_id 형식이 잘못되었습니다" unless project_id.match?(/\A[a-z][a-z0-9-]{4,28}[a-z0-9]\z/)
    raise CatalogError, "region 형식이 잘못되었습니다" unless region.match?(/\A[a-z]+-[a-z]+\d+\z/)
    raise CatalogError, "zone은 region에 속해야 합니다" unless zone.start_with?("#{region}-")
    raise CatalogError, "name_prefix 형식이 잘못되었습니다" unless name_prefix.match?(/\A[a-z][a-z0-9-]{2,30}\z/)
  end

  def validate_network!
    raise CatalogError, "network는 mapping이어야 합니다" unless network.is_a?(Hash)

    %w[dev_subnet_cidr private_services_cidr].each do |key|
      IPAddr.new(required_string(network, key))
    rescue IPAddr::InvalidAddressError
      raise CatalogError, "#{key}는 유효한 CIDR이어야 합니다"
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

  def bootstrap_variables
    {
      "project_id" => gcp.fetch("project_id"),
      "region" => gcp.fetch("region"),
      "state_bucket_name" => state.fetch("bucket")
    }
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
    end.parse!

    %i[catalog root output_root].each do |key|
      abort("#{key} 인수가 필요합니다") unless options[key]
    end

    generated = EnvironmentCatalog.load(options[:catalog]).write_terraform_inputs!(
      root: options[:root],
      output_root: options[:output_root]
    )
    puts JSON.generate(generated)
  rescue EnvironmentCatalog::CatalogError => error
    warn "환경 카탈로그 오류: #{error.message}"
    exit 1
  end
end
