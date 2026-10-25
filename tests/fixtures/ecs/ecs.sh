declare -A ECS_ENV_ALIASES=(
    [prod]="production"
    [prd]="production"
    [stg]="staging"
    [stage]="staging"
    [can]="canada"
    [ca]="canada"
)

declare -A ECS_SERVICE_ALIASES=(
    [sched]="scheduler"
    [job]="scheduler"
    [web]="portal"
    [app]="portal"
    [worker]="queue"
    [q]="queue"
    [referral]="referral-intake"
)

declare -A ECS_PROJECT_ALIASES=(
    [ap]="admin-portal"
    [admin]="admin-portal"
    [portal_dev]="admin-portal"
    [fp]="family-portal"
    [family]="family-portal"
    [pay]="payments"
)
