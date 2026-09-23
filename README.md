# notify-deploy

Tell [Struct](https://struct.ai) when a commit reaches an environment. Struct uses each deploy to review what shipped and to set up Auto Monitors for it.

Use this action when your deploys do not create GitHub Deployments, for example when they run through ArgoCD, Helm, Terraform or your own scripts. If your deploy jobs already set `environment:`, Struct can listen for GitHub Deployments instead, and you do not need this action.

## Quick start

1. **Create a deployment key.** In Struct, open **Settings → Deployment Keys** and create a key. It starts with `sk-` and is shown once.
2. **Store it as a secret.** For example, add a repository or organization secret named `STRUCT_DEPLOY_KEY`.
3. **Tell Struct which environment to watch.** In Auto Monitors (or a deployment monitor), choose **Other Webhook** as the source and enter the environment name, for example `production`.
4. **Add the step after your deploy is live:**

```yaml
- uses: struct-dot-ai/notify-deploy@v1
  with:
    api-key: ${{ secrets.STRUCT_DEPLOY_KEY }}
    environment: production
```

For a workflow that deploys one service when a commit is pushed, that is all. The commit, repository and idempotency key come from the workflow run.

## Where to put the step

Put it **after** the deploy has finished rolling out: after `kubectl rollout status`, after your ArgoCD or Helm wait, after the health check. Struct treats the report as "this commit is now live". A report sent when the deploy starts would make Struct look at production before the new code is running.

The step never fails your deploy. If Struct is unreachable or the key is wrong, the run shows an error annotation and the job carries on. Retries happen automatically for network errors and 5xx responses.

## Inputs

### Required

| Input | What to pass |
|---|---|
| `api-key` | Your Struct deployment key (`sk-…`), from a secret. Ingest keys (`pk-…`) are rejected. |
| `environment` | The environment the commit reached. It must match the name configured in Struct **exactly, including case**. A deploy to a name Struct is not watching is recorded but starts no analysis. |

### Optional

| Input | Default | Set it when |
|---|---|---|
| `sha` | `github.sha` | The workflow was not started by the deployed commit, or it deploys code from another repository. 7 to 64 hex characters; branch and tag names are rejected. |
| `repository` | the repository running the workflow | The deployed code lives in a different repository from this workflow (for example a separate deploy or GitOps repo). Use `owner/name`. Struct's GitHub App must be installed on it. |
| `status` | `success` | You also want failed deploys reported. Accepts `success`, `failure`, `error`, or `${{ job.status }}` directly; `cancelled` reports nothing. |
| `idempotency-key` | built from repository, environment, commit, run id, attempt and job | One job deploys several services, or you want your own id. See [Idempotency keys](#idempotency-keys). |
| `previous-sha` | Struct's last recorded deploy to this environment | You know which release this deploy replaced and want Struct to diff against it, for example after a rollback or a deploy Struct never heard about. |
| `api-url` | `https://api.struct.ai` | Only if Struct asks you to use a different endpoint. |
| `fail-on-error` | `false` | You would rather the step fail than warn when reporting fails. |

### Outputs

| Output | Value |
|---|---|
| `result` | `recorded`, `skipped` (status was `cancelled`) or `failed` |
| `deployment-id` | Id of the deployment Struct recorded |

## Getting the behavior you want

**One service per workflow, deployed on push.** Use the quick start as is.

**Many services deployed by one shared workflow or composite action (monorepo).** Add the step once, in the shared deploy code, and put the service name in the idempotency key. Several services shipping the same commit are then recorded as separate deploys:

```yaml
- name: Notify Struct
  if: success() && inputs.environment == 'production'
  uses: struct-dot-ai/notify-deploy@v1
  with:
    api-key: ${{ env.STRUCT_DEPLOY_KEY }}
    environment: production
    sha: ${{ inputs.commit }}
    idempotency-key: ${{ inputs.service }}-${{ inputs.commit }}
```

**The workflow is triggered by something other than the deployed commit.** With `repository_dispatch`, `workflow_run` or `schedule`, `github.sha` is the tip of your default branch, not what you shipped. The action warns about this. Pass the commit you deployed:

```yaml
    sha: ${{ github.event.client_payload.sha }}
```

**The deploy workflow lives in a different repository from the code.** Pass both the code repository and the commit:

```yaml
    repository: acme/api
    sha: ${{ steps.release.outputs.commit }}
```

**Report failed deploys too.** Run the step even when earlier steps failed, and pass the job's status:

```yaml
- if: always()
  uses: struct-dot-ai/notify-deploy@v1
  with:
    api-key: ${{ secrets.STRUCT_DEPLOY_KEY }}
    environment: production
    status: ${{ job.status }}
```

**Canary, then full rollout.** Report twice, with two environment names such as `production-canary` and `production`, and configure Struct to watch the one you care about.

**Make a broken report fail the job.** Set `fail-on-error: 'true'`.

## Idempotency keys

Struct records one deploy per idempotency key. Sending the same key again returns the deploy already recorded, so retries never create duplicates.

- **Use one key per deploy.** A fixed key such as `production` means only the first deploy is ever recorded.
- **Keep it stable across retries of the same deploy.** Do not add timestamps or random values, or a retry becomes a second deploy.
- **Include the service name when one run deploys several services.** The default includes the job name, which is enough when each service deploys in its own job.

The default key is `owner/repo:environment:sha:run_id:run_attempt:job`. A re-run of the workflow is a new attempt, so it is recorded as a new deploy.

## Troubleshooting

The step's annotation says what went wrong:

| Annotation | Fix |
|---|---|
| `api-key is empty` | The secret is not available to this job. Check its name, and note that workflows triggered from forks do not receive secrets. |
| `rejected the deployment key (401)` | The key was deleted, expired, or belongs to another Struct organization. Create a new one. |
| `cannot use this repository (403)` | Install Struct's GitHub App on the repository, or approve its pending permission request. |
| `rejected the request (422)` | An input has the wrong shape; the message names the field. |
| `sha must be a commit SHA` | Pass a commit, not a branch or tag. |
| `sha … was read as a number` | Quote an all-digit SHA in YAML: `sha: '1234567'`. |
| `Could not reach …` | The runner cannot reach `api.struct.ai`. Allow outbound HTTPS to it. |

## Security

- Pass the key from a secret. The action masks it in logs and sends it only in the `Authorization` header, never on the command line.
- A deployment key can only record deploys. It cannot read data from Struct.

## Requirements

The runner needs `bash` and `curl`, and nothing else. There is no `jq`, Python or Node dependency, so the action runs in minimal self-hosted runner containers. Linux and macOS runners are tested.

## Without this action

The action wraps one HTTP call, which you can make from any deploy tool:

```bash
curl -X POST https://api.struct.ai/api/deployments/ \
  -H "Authorization: Bearer $STRUCT_DEPLOY_KEY" \
  -H "Content-Type: application/json" \
  -d '{"repository":"acme/api","sha":"abc1234deadbeef","environment":"production","status":"success","idempotencyKey":"api-production-abc1234"}'
```

Fields: `repository`, `sha`, `environment` and `idempotencyKey` are required; `status` (default `success`) and `previousSha` are optional. See the [deployment audits docs](https://docs.struct.ai/deployment-audits) for more.

## License

[MIT](LICENSE)
