#!/usr/bin/env ruby
# frozen_string_literal: true

# Launcher NetworkPolicy checker가 실제 YAML mutation을 거부하는지 검증한다.
require "fileutils"
require "tmpdir"
require "yaml"

require_relative "check-experiment-launcher-manifest-contract"

module ExperimentLauncherManifestContractTest
  module_function

  def fixture_root
    Dir.mktmpdir("experiment-launcher-manifest-contract-").tap do |root|
      manifest_directory = File.join(root, "deploy", "agent-orchestration")
      catalog_directory = File.join(root, "config", "environments", "dev")
      FileUtils.mkdir_p(manifest_directory)
      FileUtils.mkdir_p(catalog_directory)
      # (#566/#575) digest 일관성·API token 검사가 디렉터리 전체를 보므로 fixture도
      # 전체를 복사한다. launcher manifest 하나만 두면 두 검사가 fixture마다 무조건
      # 실패해, 아래 expect_failure들이 의도한 mutation이 아닌 이유로 통과한다.
      FileUtils.cp(
        Dir.glob(File.join(File.dirname(ExperimentLauncherManifestContract::MANIFEST_PATH), "*.yaml")),
        manifest_directory
      )
      FileUtils.cp(
        ExperimentLauncherManifestContract::ENVIRONMENT_PATH,
        File.join(catalog_directory, "environment.yaml")
      )
    end
  end

  def mutate_policy(root)
    manifest_path = File.join(
      root,
      "deploy",
      "agent-orchestration",
      "launcher-cronjob.yaml"
    )
    documents = YAML.load_stream(File.read(manifest_path)).compact
    policy = documents.find { |document| document["kind"] == "NetworkPolicy" }
    raise "fixture NetworkPolicy가 없습니다" unless policy

    yield policy
    File.write(
      manifest_path,
      documents.map(&:to_yaml).join("---\n")
    )
  end

  def mutate_api_deployment(root)
    path = File.join(root, "deploy", "agent-orchestration", "api-deployment.yaml")
    documents = YAML.load_stream(File.read(path)).compact
    deployment = documents.find { |document| document["kind"] == "Deployment" }
    raise "fixture API Deployment가 없습니다" unless deployment

    yield deployment
    File.write(path, documents.map(&:to_yaml).join("---\n"))
  end

  def mutate_launcher(root)
    path = File.join(root, "deploy", "agent-orchestration", "launcher-cronjob.yaml")
    documents = YAML.load_stream(File.read(path)).compact
    cron_job = documents.find { |document| document["kind"] == "CronJob" }
    raise "fixture CronJob이 없습니다" unless cron_job

    yield cron_job
    File.write(path, documents.map(&:to_yaml).join("---\n"))
  end

  def expect_equal(expected, actual, description)
    return if expected == actual

    raise "#{description} 불일치: 기대=#{expected.inspect}, 실제=#{actual.inspect}"
  end

  def check_training_release_pins!
    documents = YAML.load_stream(
      File.read(ExperimentLauncherManifestContract::MANIFEST_PATH)
    ).compact
    cron_job = documents.find { |document| document["kind"] == "CronJob" }
    container = cron_job.dig(
      "spec", "jobTemplate", "spec", "template", "spec", "containers", 0
    )
    environment = container.fetch("env").to_h { |item| [item.fetch("name"), item] }

    expect_equal(
      "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher@sha256:5df85dc4f4c66f2503310dd610005fa180a80ad86bfc20575bff5bb86dce4e41",
      container.fetch("image"),
      "launcher image"
    )
    expected = {
      "ORCH_EXECUTOR_IMAGE" => "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:49f15d54b3cdb15c22912364b0b89bd457fa3fcdeee132a952bebb0908344625",
      "ORCH_TRAINING_DATASET_URI" => "gs://autoresearch-503903-autoresearch-dev-experiment-results/training-snapshots/by-hash/d3d273e66324042cd8e547068c194231cf1812d53cb68236edba56b067055293/",
      "ORCH_TRAINING_TIMEOUT_SEC" => "1800",
      "ORCH_TRAINING_DOWNLOAD_TIMEOUT_SEC" => "600",
      "ORCH_UV_SYNC_TIMEOUT_SEC" => "900",
      "ORCH_MLFLOW_TRACKING_URI" => "http://mlflow.mlflow.svc.cluster.local:5000"
    }
    expected.each do |name, value|
      expect_equal({ "name" => name, "value" => value }, environment.fetch(name), name)
    end
    raise "구식 ORCH_TRAINING_DATASET_PATH가 남아 있습니다" if environment.key?("ORCH_TRAINING_DATASET_PATH")
  end

  def expect_failure(label)
    root = fixture_root
    yield root
    begin
      ExperimentLauncherManifestContract.check!(root)
    rescue ExperimentLauncherManifestContract::ContractError
      return
    ensure
      FileUtils.remove_entry(root) if File.exist?(root)
    end
    raise "#{label} mutation을 감지하지 못했습니다"
  end

  def run!
    ExperimentLauncherManifestContract.check!
    check_training_release_pins!

    expect_failure("공개 인터넷 egress 추가") do |root|
      mutate_policy(root) do |policy|
        policy.dig("spec", "egress") << {
          "to" => [{ "ipBlock" => { "cidr" => "0.0.0.0/0" } }],
          "ports" => [{ "protocol" => "TCP", "port" => 443 }]
        }
      end
    end

    expect_failure("Cloud SQL 포트 변경") do |root|
      mutate_policy(root) do |policy|
        rule = policy.dig("spec", "egress").find do |item|
          item.dig("to", 0, "ipBlock", "cidr") == "192.168.0.0/20"
        end
        rule.fetch("ports").first["port"] = 3306
      end
    end

    expect_failure("Kubernetes API service VIP 변경") do |root|
      mutate_policy(root) do |policy|
        target = policy.dig("spec", "egress")
          .flat_map { |item| item.fetch("to", []) }
          .find { |item| item.dig("ipBlock", "cidr") == "172.16.128.1/32" }
        target.fetch("ipBlock")["cidr"] = "172.16.128.2/32"
      end
    end

    expect_failure("예상하지 않은 namespaceSelector 추가") do |root|
      mutate_policy(root) do |policy|
        policy.dig("spec", "egress") << {
          "to" => [{
            "namespaceSelector" => {
              "matchLabels" => { "kubernetes.io/metadata.name" => "default" }
            }
          }],
          "ports" => [{ "protocol" => "TCP", "port" => 443 }]
        }
      end
    end

    expect_failure("Secret Manager VIP 삭제") do |root|
      mutate_policy(root) do |policy|
        policy.dig("spec", "egress").reject! do |item|
          item.dig("to", 0, "ipBlock", "cidr") == "199.36.153.8/30"
        end
      end
    end

    # (#566) 승격이 일부 manifest만 갱신하면 서로 다른 커밋의 이미지가 한 배포에
    # 섞인다. fixture는 launcher-cronjob.yaml 하나만 복사하므로, 같은 이미지를
    # 다른 digest로 참조하는 manifest를 하나 더 놓아 검사를 실행시킨다.
    expect_failure("같은 이미지의 digest 불일치") do |root|
      manifest_directory = File.join(root, "deploy", "agent-orchestration")
      launcher = YAML.load_stream(
        File.read(File.join(manifest_directory, "launcher-cronjob.yaml"))
      ).compact.find { |document| document["kind"] == "CronJob" }
      bootstrap_image = launcher.dig(
        "spec", "jobTemplate", "spec", "template", "spec", "initContainers", 0, "image"
      )
      repository = bootstrap_image.split("@", 2).fetch(0)

      File.write(
        File.join(manifest_directory, "zz-stale-digest.yaml"),
        {
          "apiVersion" => "apps/v1",
          "kind" => "Deployment",
          "metadata" => { "name" => "stale" },
          "spec" => {
            "template" => {
              "spec" => {
                "containers" => [{
                  "name" => "stale",
                  "image" => "#{repository}@sha256:#{'0' * 64}"
                }]
              }
            }
          }
        }.to_yaml
      )
    end

    # (#575) 이 참조가 없으면 새 API image가 startup에서 죽는데, Service는 직전
    # Pod를 Ready로 유지해 배포가 성공한 것처럼 보인다. 정적으로 잡아야 한다.
    expect_failure("API의 ORCH_EXECUTOR_API_TOKEN 참조 삭제") do |root|
      mutate_api_deployment(root) do |deployment|
        deployment.dig("spec", "template", "spec", "containers").each do |container|
          container["env"]&.reject! { |item| item["name"] == "ORCH_EXECUTOR_API_TOKEN" }
        end
      end
    end

    expect_failure("API의 executor token Secret key 변경") do |root|
      mutate_api_deployment(root) do |deployment|
        entry = deployment.dig("spec", "template", "spec", "containers")
          .flat_map { |container| container["env"] || [] }
          .find { |item| item["name"] == "ORCH_EXECUTOR_API_TOKEN" }
        entry.dig("valueFrom", "secretKeyRef")["key"] = "ORCH_EXECUTOR_API_TOKEN"
      end
    end

    expect_failure("smoke 기간 TTL 3600 고정 위반") do |root|
      mutate_launcher(root) do |cron_job|
        environment = cron_job.dig(
          "spec", "jobTemplate", "spec", "template", "spec", "containers", 0, "env"
        )
        environment.find do |item|
          item["name"] == "ORCH_TTL_AFTER_FINISHED_SEC"
        end["value"] = "30"
      end
    end

    # (#591) 학습은 URI가 opt-in 스위치이고 timeout 세 값도 v0.9.0 launcher가
    # 필수로 읽으므로, 하나라도 변경·누락되거나 구식 PATH가 재유입되면 거부한다.
    expect_failure("학습 snapshot URI 변경") do |root|
      mutate_launcher(root) do |cron_job|
        environment = cron_job.dig(
          "spec", "jobTemplate", "spec", "template", "spec", "containers", 0, "env"
        )
        environment.find { |item| item["name"] == "ORCH_TRAINING_DATASET_URI" }["value"] =
          "gs://autoresearch-503903-autoresearch-dev-experiment-results/training-snapshots/"
      end
    end

    expect_failure("학습 timeout 누락") do |root|
      mutate_launcher(root) do |cron_job|
        environment = cron_job.dig(
          "spec", "jobTemplate", "spec", "template", "spec", "containers", 0, "env"
        )
        environment.reject! { |item| item["name"] == "ORCH_TRAINING_TIMEOUT_SEC" }
      end
    end

    # (#599) 이 둘은 실패가 조용하다 — mlflow가 Pod 로컬 file store로 fallback하고
    # 학습은 exit 0으로 끝나므로, 비교 판정 단계에 가서야 run이 없다는 걸 안다.
    expect_failure("MLflow tracking 좌표 누락") do |root|
      mutate_launcher(root) do |cron_job|
        environment = cron_job.dig(
          "spec", "jobTemplate", "spec", "template", "spec", "containers", 0, "env"
        )
        environment.reject! { |item| item["name"] == "ORCH_MLFLOW_TRACKING_URI" }
      end
    end

    expect_failure("MLflow tracking 좌표 변경") do |root|
      mutate_launcher(root) do |cron_job|
        environment = cron_job.dig(
          "spec", "jobTemplate", "spec", "template", "spec", "containers", 0, "env"
        )
        entry = environment.find { |item| item["name"] == "ORCH_MLFLOW_TRACKING_URI" }
        entry["value"] = "http://mlflow.mlflow.svc.cluster.local:8080"
      end
    end

    expect_failure("구식 학습 dataset path 재유입") do |root|
      mutate_launcher(root) do |cron_job|
        environment = cron_job.dig(
          "spec", "jobTemplate", "spec", "template", "spec", "containers", 0, "env"
        )
        environment << {
          "name" => "ORCH_TRAINING_DATASET_PATH",
          "value" => "/workspace/training_dataset.csv"
        }
      end
    end

    expect_failure("환경 카탈로그 services CIDR drift") do |root|
      environment_path = File.join(
        root,
        "config",
        "environments",
        "dev",
        "environment.yaml"
      )
      environment = YAML.safe_load(File.read(environment_path))
      environment.fetch("gke")["services_cidr"] = "172.16.129.0/24"
      File.write(environment_path, environment.to_yaml)
    end
  end
end

ExperimentLauncherManifestContractTest.run!
puts "Experiment launcher manifest contract self-test: passed"
