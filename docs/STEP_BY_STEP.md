# Step-by-step execution guide

How to take this repository from your laptop to a finished, evidenced submission within the 72-hour window.
Each step lists **what's already in the repo**, **what you run**, **what evidence to capture**, and **the git commits/PR** to make.

> Reviewers grade git practice too: use one branch + PR per step, small commits with clear messages
> (Conventional Commits shown below), and let `pr.yml` run on every PR.

---

## Task analysis (from the brief)

| # | Step | Graded on | Key "must not miss" items |
|---|---|---|---|
| 1 | App + container | image size, layers, hardening, runtime hygiene | `/`, `/health`, `/metrics` (count, errors, latency histogram) · env config · JSON logs · SIGTERM · tests · multi-stage, pinned, non-root, HEALTHCHECK, OCI labels, `.dockerignore` · **state image size** · compose: 8080, healthcheck, restart, limits |
| 2 | CI/CD | structure, gates, caching, tagging, safe deploy + rollback | PR: lint, tests, coverage, hadolint, shellcheck, Trivy **fails on CRITICAL** · main: amd64+arm64, cache, SHA + semver tags, push, OIDC, deploy via SSM, smoke `/health`, **auto rollback** · document secrets/vars |
| 3 | Terraform | least privilege, reuse, state | EC2 + SG (minimal ports) · IAM profile (ECR pull, CW logs) · user data installs Docker + runs app · logs → CloudWatch w/ retention · S3 state + locking · staging/prod via vars · **plan + apply evidence, then destroy** |
| 4 | Kubernetes | probes, resources, securityContext, rollout/rollback | ≥ 2 replicas, rolling update, probes · requests/limits · Service + Ingress · ConfigMap + Secret (not committed) · non-root + RO rootfs · HPA · **rollout + undo commands & output in README** · EKS notes |
| 5 | Observability | meaningful dashboards, log handling, actionable alerts, as code | all 6 components · retention for Prometheus **and** Loki · JSON parsing, low cardinality explained · 3 dashboards as JSON, provisioned · Loki panel beside metrics · ≥ 4 alerts with reasoning · creds from env · **only Grafana exposed** · pinned images · mounts documented · **screenshots + walkthrough** |
| 6 | Bash script | robustness, errors, config, readability | CPU/mem/disk/load/top-5 · log + `--json` · threshold flags · exit codes 0/1/2 · rotation · `set -euo pipefail`, shellcheck, `--help` · cron or systemd timer |
| 7 | README | clarity, reproducibility, reasoning | run instructions · architecture diagram · design decisions · deploy/rollback · security · cost · improvements · AI note |

---

## Suggested 3-day plan

| Day | Morning | Afternoon | Evening |
|---|---|---|---|
| 1 | Step 0 + Step 1 (build, measure image size) | Step 2 PR workflow green | Step 5 stack running locally, screenshots |
| 2 | Step 3 bootstrap + global, first `main` push to ECR | Step 3 app stack staging, deploy via CI | Step 4 kind + rollout demo |
| 3 | Step 6 on a Linux box/VM, timer installed | README placeholders, evidence | Destroy AWS resources, final review, submit link |

---

## Step 0 — Repository setup

```bash
cd CareGuide
git init -b main
git add .gitignore .dockerignore .env.example README.md docs/ Makefile VERSION
git commit -m "chore: initial repository skeleton and documentation outline"
gh repo create CareGuide --public --source=. --push      # or create on github.com and `git push -u origin main`
```

Then in GitHub **Settings**:
- *Branches* → protect `main`: require PR, require status checks (`Lint, test & coverage`, `Dockerfile, shell, Terraform & K8s lint`, `Build image & Trivy scan`).
- *Environments* → create `staging` and `production` (production: required reviewer = you, deployment branch `main`).
- Replace `<your-github-user>` in `Dockerfile` and `scripts/systemd/system-health.service`.

## Step 1 — Application & containerization

```bash
git switch -c feat/app-container

python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
ruff check . && ruff format --check .
python -m pytest --cov=app --cov-report=term-missing     # expect 7 passed, ~92% coverage

make build                                              # prints "Image size: ..."
docker image ls careguide-api                            # → put the size in README (Step 1 section)
docker inspect careguide-api:1.0.0 --format '{{.Config.User}} {{json .Config.Labels}}'

docker compose up -d --build
docker compose ps                                        # STATUS should become "healthy"
curl -s localhost:8080/ ; curl -s localhost:8080/health ; curl -s localhost:8080/metrics | grep http_
docker compose logs app | head                           # JSON lines
docker compose stop app && docker compose logs app | tail -3   # "application shutting down gracefully"
```

Commits:
```
feat(app): add FastAPI service with /, /health and /metrics endpoints
feat(app): structured JSON logging and env-based configuration
test(app): unit tests for endpoints, config and log formatter
build(docker): multi-stage distroless Dockerfile with healthcheck and OCI labels
build(compose): local docker-compose with healthcheck, restart policy and limits
docs: document image size and local run instructions
```
Open the PR → it is the first run of `pr.yml` (merged in the next step if the workflow isn't on `main` yet; simplest is to include `.github/workflows/pr.yml` in this PR).

## Step 2 — CI/CD

```bash
git switch main && git pull && git switch -c ci/github-actions
git add .github/workflows/
git commit -m "ci: PR pipeline with lint, tests, coverage, hadolint, shellcheck and Trivy gate"
git commit -m "ci: multi-arch build, ECR push with OIDC, SSM deploy with smoke test and rollback"   # (split adds as you prefer)
git push -u origin ci/github-actions && gh pr create --fill
```

- Wait for `pr.yml` to go green; screenshot the checks + job summary (coverage, image size) → `docs/screenshots/ci-pr.png`.
- **Prove the gate works (optional but strong):** temporarily change the runtime base to an old image (e.g. `python:3.8-slim-buster`) in a throwaway PR, show Trivy failing, close the PR.
- `main.yml` needs AWS — it will succeed after Step 3's `global` stack exists and the secret/variables are set.

## Step 3 — Terraform

```bash
git switch -c infra/terraform
aws sts get-caller-identity                       # confirm the account

# bootstrap (once)
cd terraform/bootstrap
terraform init && terraform apply -var="state_bucket_name=careguide-tfstate-$(whoami)-$RANDOM"
cd .. && cp backend.hcl.example backend.hcl && $EDITOR backend.hcl

# global: ECR + OIDC role
terraform -chdir=global init -backend-config=../backend.hcl -backend-config="key=careguide/global/terraform.tfstate"
terraform -chdir=global apply -var="github_repository=<owner>/CareGuide"
terraform -chdir=global output
```

Configure GitHub: secret `AWS_GITHUB_ROLE_ARN`, variables `AWS_REGION`, `ECR_REPOSITORY=careguide-api`.
Merge the CI PR (or re-run `main.yml` via *workflow_dispatch*) so the first image is pushed to ECR. Deploy jobs will fail until the instances exist — expected.

```bash
# staging environment
terraform -chdir=app init -backend-config=../backend.hcl -backend-config="key=careguide/staging/terraform.tfstate"
terraform -chdir=app plan -var-file=environments/staging.tfvars -out=staging.tfplan | tee /tmp/plan.txt
terraform -chdir=app apply staging.tfplan
IP=$(terraform -chdir=app output -raw public_ip)
sleep 90; curl -s http://$IP/health; curl -s http://$IP/
aws logs tail /careguide/staging/app --since 10m      # container logs in CloudWatch
aws ssm start-session --target $(terraform -chdir=app output -raw instance_id)   # then: sudo /opt/careguide/deploy.sh --status
```

Now re-run `main.yml` → staging deploy succeeds; approve production only if you also applied `production.tfvars` (optional — staging is enough for evidence).

**Test the rollback (strong evidence):** in a throwaway branch make `/health` return 500, merge, watch the deploy log show `health check FAILED` → `rolling back to sha-...` and the job fail; revert.

Evidence → `docs/screenshots/`: `terraform-plan.png`, `terraform-apply.png`, `ci-main-deploy.png`, `cloudwatch-logs.png`, (`ci-rollback.png`).

```bash
# Destroy when done (keep the evidence!)
terraform -chdir=app destroy -var-file=environments/staging.tfvars
# optional: terraform -chdir=global destroy ...   (bootstrap bucket has prevent_destroy)
```

Commits:
```
feat(terraform): bootstrap S3 remote state with versioning and encryption
feat(terraform): ECR repository and GitHub OIDC deploy role
feat(terraform): EC2 deployment target with least-privilege instance profile
feat(terraform): CloudWatch log group and Docker bootstrap user data
feat(terraform): staging and production variable files
```

## Step 4 — Kubernetes

```bash
git switch -c feat/k8s
make kind-up            # cluster + ingress-nginx + metrics-server
make kind-load          # careguide-api:1.0.0 into kind
make k8s-deploy
kubectl -n careguide get all,ingress,hpa,pdb
curl -s http://careguide.localtest.me/
kubectl -n careguide top pods                     # metrics-server works → HPA shows a target %

make k8s-rollout-demo | tee /tmp/rollout.txt      # paste into README "Output from my run"
```

Optional HPA proof: `kubectl -n careguide run load --rm -it --image=busybox:1.36 --restart=Never -- sh -c 'while true; do wget -qO- http://careguide-api/ >/dev/null; done'` and watch `kubectl -n careguide get hpa -w`.
(Note: the namespace enforces Pod Security `restricted`; if the busybox pod is rejected, run it in `default`, targeting `http://careguide-api.careguide/`.)

Commits:
```
feat(k8s): deployment with probes, resources and hardened securityContext
feat(k8s): service, ingress, configmap and out-of-band secret approach
feat(k8s): HPA, PDB and network policy
docs(k8s): rollout/rollback demo output and EKS production notes
```

## Step 5 — Observability

```bash
git switch -c feat/observability
cp .env.example .env && $EDITOR .env               # set GRAFANA_ADMIN_PASSWORD
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --build
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml ps

# prove only Grafana is published
docker ps --format '{{.Names}}\t{{.Ports}}'        # only careguide-app 8080 and grafana 3000

# traffic + an error spike
for i in $(seq 1 500); do curl -s localhost:8080/ >/dev/null; sleep 0.05; done &
for i in $(seq 1 60);  do curl -s localhost:8080/chaos/error >/dev/null; sleep 1; done
```

Open http://localhost:3000 → *CareGuide* folder. Wait ~5 min during the spike so `CareGuideHighErrorRate` goes **Firing** (check Grafana *Alerting → Alert rules* or Prometheus via `docker compose exec grafana wget -qO- http://prometheus:9090/api/v1/alerts`).

Screenshots → `docs/screenshots/`: `grafana-application.png` (show the spike + logs panel), `grafana-host.png`, `grafana-containers.png`, `alert-firing.png`. Then add them to the README:

```markdown
![Application dashboard](docs/screenshots/grafana-application.png)
```

Validate as code:
```bash
promtool test rules monitoring/prometheus/tests/alerts_test.yml      # or via docker, see pr.yml
```

Commits:
```
feat(monitoring): prometheus with scrape config, retention and alert rules
test(monitoring): promtool unit tests for alert rules
feat(monitoring): loki with retention and alloy docker log pipeline with JSON parsing
feat(monitoring): node-exporter and cadvisor on an internal network
feat(monitoring): grafana provisioning with application, host and container dashboards
feat(monitoring): alertmanager slack routing (optional profile)
docs(monitoring): screenshots, label strategy, alert reasoning and incident walkthrough
```

## Step 6 — Health script

Run on any Linux host (the EC2 instance via Session Manager, a VM, or WSL — not macOS, it needs `/proc`):

```bash
git switch -c feat/health-script
shellcheck scripts/system_health.sh                       # no output = clean
./scripts/system_health.sh --help
./scripts/system_health.sh; echo "exit=$?"
./scripts/system_health.sh --json | jq .
./scripts/system_health.sh --mem 5 -q; echo "exit=$?"      # force a WARNING → exit 1
./scripts/system_health.sh --disk 1 --disk-crit 2 -q; echo "exit=$?"   # force CRITICAL → exit 2

# install the timer
sudo install -m 0755 scripts/system_health.sh /usr/local/bin/
sudo cp scripts/systemd/system-health.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now system-health.timer
systemctl list-timers system-health.timer
sudo tail -n 2 /var/log/system-health/health_log.txt
```

Commits:
```
feat(scripts): system_health.sh with thresholds, JSON output and exit codes
feat(scripts): log rotation and webhook alerts for system_health.sh
feat(scripts): systemd service/timer and cron entry for 5-minute runs
```

## Step 7 — Documentation & submission

Fill every `<...>` placeholder in `README.md`:

- [ ] Final image size (Step 1)
- [ ] CI screenshots (Step 2)
- [ ] Terraform plan/apply + CloudWatch screenshots (Step 3)
- [ ] Rollout demo output (Step 4)
- [ ] Three dashboard screenshots + alert firing (Step 5)
- [ ] AI-usage note in your own words
- [ ] `<your-github-user>` replaced everywhere: `grep -rn "<your-github-user>" .`
- [ ] No secrets committed: `git log -p | grep -iE "hooks.slack|password=|AKIA" || echo clean`
- [ ] AWS resources destroyed: `aws ec2 describe-instances --filters Name=tag:Project,Values=careguide --query 'Reservations[].Instances[].State.Name'`

Final check from a fresh clone (what the reviewer will do):
```bash
git clone https://github.com/<you>/CareGuide.git /tmp/review && cd /tmp/review
cp .env.example .env && docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d --build
```

Submit the public repository URL.

---

## Interview prep — be ready to explain

- Why distroless, and how you debug a container without a shell (`kubectl debug`, ephemeral containers).
- Why `maxUnavailable: 0` + readiness probe + preStop sleep give zero downtime.
- How OIDC trust conditions (`sub` claim) stop PRs/forks from deploying.
- Why `path` is structured metadata and not a Loki label; what happens to Loki with high-cardinality labels.
- Why the error-rate alert has a traffic floor and a 5-minute `for`.
- What happens step by step when the deploy health check fails on EC2.
- What you'd change for production (ALB/HTTPS, ECS or EKS, GitOps, SLO burn-rate alerts).
