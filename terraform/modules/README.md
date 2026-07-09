# Terraform Modules

재사용 가능한 Terraform module을 두는 디렉터리입니다.

현재 module은 없습니다. 초기에 module화를 검토했던 network/artifact-registry/
cloud-sql/gke/github-oidc(#2~#6)는 모두 `terraform/envs/dev` root에 직접
구현하는 것으로 종결되었습니다.

staging/prod 환경 분리 등으로 동일 구성을 재사용할 필요가 생기면 그 시점에
dev root에서 module을 추출합니다.
