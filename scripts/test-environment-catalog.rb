#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
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

VALID_CATALOG = <<~YAML.freeze
  schema_version: 1
  environment: dev
  gcp:
    project_id: autoresearch-503903
    region: asia-northeast3
    zone: asia-northeast3-a
    name_prefix: autoresearch
  network:
    dev_subnet_cidr: 10.10.0.0/20
    private_services_cidr: 192.168.0.0/20
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
end

puts "환경 카탈로그 검증 테스트: 통과"
