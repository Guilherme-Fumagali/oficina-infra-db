# oficina-infra-db

Infraestrutura do **banco de dados gerenciado** do Tech Challenge Fase 3 — PosTech FIAP, Arquitetura de Software.

Um dos quatro repositórios da entrega. Os outros: `oficina-api` (aplicação), `oficina-auth-lambda` (autenticação por CPF) e `oficina-infra-k8s` (rede, EKS, API Gateway).

## Propósito

Provisiona por Terraform o **Amazon RDS PostgreSQL 16** que sustenta a aplicação e a Lambda de autenticação, em subnet privada, acessível apenas pelos nós do EKS e pela função de autenticação.

## Arquitetura

```
      VPC 10.0.0.0/16  (propriedade do repo oficina-infra-k8s)
      ┌──────────────────────────────────────────────────┐
      │                                                  │
      │  subnet privada 10.0.11.0/24 (us-east-1a)        │
      │  subnet privada 10.0.12.0/24 (us-east-1b)        │
      │        │                                         │
      │        │  ┌────────────────────────────────┐     │
      │        └─▶│  RDS PostgreSQL 16             │     │
      │           │  db.t4g.micro · 20 GB gp3      │     │
      │           │  Single-AZ · criptografado     │     │
      │           │  publicly_accessible = false   │     │
      │           └───────────▲──────────▲─────────┘     │
      │                       │          │               │
      │      security group   │          │               │
      │      porta 5432 só de │          │               │
      │                       │          │               │
      │            nós do EKS ┘          └ Lambda auth   │
      └──────────────────────────────────────────────────┘
```

## Tecnologias

- **Terraform 1.9.8** · provider AWS ~> 5.70
- **Amazon RDS PostgreSQL 16**
- Backend de state em **S3 + DynamoDB** (lock), compartilhado com os demais repos por chaves distintas

## Recursos provisionados

| Recurso | Detalhe |
|---|---|
| `aws_db_instance` | PostgreSQL 16, `db.t4g.micro`, 20 GB gp3, criptografado, Single-AZ |
| `aws_db_subnet_group` | **subnets privadas** — na Fase 2 usava as públicas |
| `aws_security_group` + regras | porta 5432 apenas dos SGs dos nós do EKS e da Lambda |
| `aws_db_parameter_group` | `log_min_duration_statement = 1000`, `log_connections = 1` |
| `aws_ssm_parameter` × 4 | endpoint, nome, usuário e senha publicados para os outros repos |

## Contrato com os outros repositórios

Acoplamento único: **SSM Parameter Store** sob `/oficina/<ambiente>/`.

| Parâmetro | Direção |
|---|---|
| `vpc-id`, `private-subnet-ids` | consome de `oficina-infra-k8s` |
| `eks-node-security-group-id`, `lambda-security-group-id` | consome de `oficina-infra-k8s` |
| `db-endpoint`, `db-name`, `db-username` | **publica** |
| `db-password` (SecureString) | **publica** |

Consumo por `data "aws_ssm_parameter"`, nunca por `terraform_remote_state` — assim este repo não precisa de permissão no state alheio.

## Execução

O RDS **só sobe pelo workflow Terraform, disparado à mão** na branch do ambiente: `develop` cria `oficina-api-db-staging` (homologação, sem aprovação), `main` cria `oficina-api-db-prod` (produção, com aprovação no environment `prod`). Push em `develop` ou `main` roda validate e plan, e o plan é pulado se o cluster do ambiente estiver desligado; outras branches rodam só validate. Pré-requisito: a rede já provisionada por `oficina-infra-k8s`.

```bash
gh workflow run terraform.yml --repo Guilherme-Fumagali/oficina-infra-db --ref develop
```

Verificação sem credenciais:

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
```

Destruir ao encerrar a sessão de trabalho — o RDS custa ~US$ 14/mês ligado. Pelo workflow **Destroy AWS**, na branch do ambiente:

```bash
gh workflow run destroy-aws.yml --repo Guilherme-Fumagali/oficina-infra-db --ref develop
```

Destruir **depois** de `oficina-auth-lambda` e **antes** do cluster de `oficina-infra-k8s`: o Terraform lê a rede do SSM, publicada pelo cluster.

> `skip_final_snapshot = true` e `deletion_protection = false`: o destroy **apaga os dados** sem rede de proteção. É consciente — destruir o ambiente entre sessões é a estratégia de custo da fase.

## Deploy

Manual, por ambiente. `develop` e `main` são protegidas, merge só por Pull Request com o check `Format & validate`. A role da pipeline só aceita token de `develop`/`staging` e `main`/`prod`.

A senha do banco é gerada pelo próprio Terraform (`random_password`), uma por ambiente, e publicada como SecureString no SSM. Não existe secret de banco no GitHub.

Ordem entre repositórios: este é o **passo 2**, depois de `oficina-infra-k8s` criar a rede e antes de `oficina-api` rodar as migrations.

## Justificativa da escolha do banco

Registrada na ADR-010 do plano de implementação. Em resumo: o domínio é relacional, com integridade referencial em cinco tabelas e junção em toda consulta de ordem de serviço. DynamoDB exigiria desnormalizar e reescrever a persistência; Aurora Serverless custa mais na capacidade mínima do que a instância usada. O schema já depende de `pgcrypto` e `gen_random_uuid()`.

**Limitações aceitas conscientemente:** Single-AZ sem failover automático; ~85 conexões no `db.t4g.micro`, o que motiva a concorrência reservada de 10 na Lambda; sem snapshot final.
