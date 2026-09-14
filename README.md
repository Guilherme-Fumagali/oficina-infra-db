# oficina-infra-db

Infraestrutura do banco de dados gerenciado do sistema de gestão de oficina mecânica, desenvolvida no Tech Challenge da PosTech FIAP (Arquitetura de Software).

| Repositório | Conteúdo |
|---|---|
| [tech-challenge-1](https://github.com/Guilherme-Fumagali/tech-challenge-1) | Aplicação oficina-api |
| [oficina-auth-lambda](https://github.com/Guilherme-Fumagali/oficina-auth-lambda) | Autenticação por CPF |
| [oficina-infra-k8s](https://github.com/Guilherme-Fumagali/oficina-infra-k8s) | Rede, EKS, ECR, API Gateway e New Relic |
| **oficina-infra-db** | RDS PostgreSQL (este repositório) |

## Propósito

Provisiona com Terraform o Amazon RDS PostgreSQL 16 utilizado pela aplicação e pela Lambda de autenticação, em subnets privadas e acessível apenas pelos nós do EKS e pela função de autenticação.

## Arquitetura

```
      VPC 10.0.0.0/16  (criada pelo oficina-infra-k8s)
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
      │      security group:  │          │               │
      │      porta 5432 apenas│          │               │
      │                       │          │               │
      │            nós do EKS ┘          └ Lambda auth   │
      └──────────────────────────────────────────────────┘
```

## Tecnologias

- Terraform 1.9.8, providers AWS ~> 5.70 e Random ~> 3.6
- Amazon RDS PostgreSQL 16
- Backend de state em S3 com lock em DynamoDB, com chave própria por ambiente

## Recursos provisionados

| Recurso | Detalhe |
|---|---|
| `aws_db_instance` | PostgreSQL 16, `db.t4g.micro`, 20 GB gp3, criptografado, Single-AZ, `oficina-api-db-<ambiente>` |
| `aws_db_subnet_group` | subnets privadas (na Fase 2 eram públicas) |
| `aws_security_group` e regras | porta 5432 liberada apenas para os security groups dos nós do EKS e da Lambda |
| `aws_db_instance` (segurança) | autenticação IAM habilitada e cópia de tags para snapshots |
| `aws_db_parameter_group` | `log_min_duration_statement = 1000`, `log_connections = 1` e `rds.force_ssl = 1` (conexões somente com TLS) |
| `random_password` | senha do banco gerada pelo Terraform, uma por ambiente |
| `aws_ssm_parameter` × 4 | endpoint, nome, usuário e senha publicados para os demais repositórios |

## Modelo de dados

O schema é criado pelas migrations Flyway da aplicação. A justificativa da escolha do banco, o diagrama entidade-relacionamento e a descrição dos relacionamentos estão no repositório da aplicação:

- [RFC-002 — escolha do banco](https://github.com/Guilherme-Fumagali/tech-challenge-1/blob/main/docs/tech-challenge-3/rfcs/RFC-002-escolha-do-banco.md)
- [ADR-010 — PostgreSQL em RDS](https://github.com/Guilherme-Fumagali/tech-challenge-1/blob/main/docs/tech-challenge-3/adrs/ADR-010-postgresql-rds.md)
- [Diagrama entidade-relacionamento](https://github.com/Guilherme-Fumagali/tech-challenge-1/blob/main/docs/tech-challenge-3/diagramas/der-modelo-relacional.md)

Em resumo, o domínio é relacional, com integridade referencial entre cinco tabelas e junções nas consultas de ordens de serviço, e o schema utiliza recursos do PostgreSQL como `pgcrypto` e `gen_random_uuid()`. DynamoDB exigiria desnormalizar e reescrever a persistência, e o Aurora Serverless tem capacidade mínima mais cara que a instância utilizada.

## Ambientes

| Branch | Instância | GitHub Environment | Aprovação |
|---|---|---|---|
| `develop` | `oficina-api-db-staging` (homologação) | `staging` | não |
| `main` | `oficina-api-db-prod` (produção) | `prod` | sim |

Cada ambiente usa a rede do cluster correspondente, state próprio (`infra-db/<ambiente>`) e senha própria.

## CI/CD e validação

Workflow [`terraform.yml`](.github/workflows/terraform.yml):

| Job | Quando executa | O que faz |
|---|---|---|
| Format & validate | todo push, em qualquer branch | `terraform fmt -check`, `terraform validate`, tflint (regras recomendadas e ruleset AWS) e checkov |
| Plan | push ou disparo manual em `develop` e `main` | verifica se a rede do ambiente existe no SSM; se existir, executa `terraform plan`, e se não existir, conclui com aviso |
| Apply | somente por `workflow_dispatch` em `develop` ou `main` | `terraform apply` no GitHub Environment do ambiente; em `main`, aguarda aprovação |

O checkov falha o job para qualquer verificação não listada em [`.checkov.yaml`](.checkov.yaml). As supressões e o motivo:

| Verificação | Motivo |
|---|---|
| `CKV_AWS_157`, `CKV_AWS_118`, `CKV_AWS_353`, `CKV_AWS_354` | Multi-AZ, enhanced monitoring e Performance Insights têm custo e não são necessários em ambiente de estudo |
| `CKV_AWS_129` | logs lentos e de conexão ficam no parameter group, consultáveis no console do RDS, sem custo de exportação |
| `CKV_AWS_293` | o ambiente é destruído ao final de cada sessão |
| `CKV_AWS_337`, `CKV2_AWS_34` | parâmetros com chave gerenciada pela AWS; somente a senha é `SecureString` |

O RDS é provisionado apenas por disparo manual, para que um merge não crie um recurso com custo. As branches `develop` e `main` não aceitam push direto; o merge exige Pull Request com uma aprovação e o job **Format & validate** concluído com sucesso. O plano não é salvo como artifact, e a autenticação na AWS usa OIDC com uma role exclusiva deste repositório.

## Execução

Pré-requisito: a rede do ambiente provisionada pelo `oficina-infra-k8s` (passo 1 da ordem de provisionamento).

```bash
gh workflow run terraform.yml --repo Guilherme-Fumagali/oficina-infra-db --ref develop
```

Validação sem credenciais:

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
```

Ordem entre repositórios:

```
1. oficina-infra-k8s   cluster, apply 1 (rede)
2. oficina-infra-db    RDS (este repositório)
3. oficina-auth-lambda funções
4. oficina-infra-k8s   cluster, apply 2 (rotas e manifests; a aplicação executa as migrations)
```

## Destruição

O RDS custa cerca de US$ 14 por mês quando provisionado e é destruído ao final de cada sessão de trabalho, pelo workflow **Destroy AWS**, na branch do ambiente:

```bash
gh workflow run destroy-aws.yml --repo Guilherme-Fumagali/oficina-infra-db --ref develop
```

A destruição deve ocorrer depois da remoção da Lambda e antes da destruição do cluster, pois o Terraform lê do SSM a rede publicada pelo cluster.

A instância usa `skip_final_snapshot = true` e `deletion_protection = false`, portanto a destruição remove os dados. Essa configuração é adequada ao uso do ambiente em sessões de estudo.

## Integração com os outros repositórios

A integração é feita pelo SSM Parameter Store, sob `/oficina/<ambiente>/`, lida por `data "aws_ssm_parameter"`, sem acesso ao state de outros repositórios.

| Parâmetro | Direção |
|---|---|
| `vpc-id`, `private-subnet-ids` | consumido de `oficina-infra-k8s` |
| `eks-node-security-group-id`, `lambda-security-group-id` | consumido de `oficina-infra-k8s` |
| `db-endpoint`, `db-name`, `db-username` | publicado |
| `db-password` (SecureString) | publicado |

## Limitações

- Instância Single-AZ, sem failover automático.
- Cerca de 85 conexões simultâneas no `db.t4g.micro`, o que motivou a concorrência reservada de 10 execuções na Lambda.
- Sem snapshot final na destruição.
