# CloudWatch Queries

<!-- TODO: fill in with real log groups, metric namespaces/dimensions, and
Logs Insights query patterns once confirmed against the actual AWS
account/region this agent runs against. Structure below is a starting
skeleton, not yet validated against real data. -->

## When to load this skill

Any question that needs CloudWatch logs or metrics: error rates, latency,
alarm history, log search across services.

## Metrics

```bash
aws cloudwatch get-metric-data \
  --metric-data-queries file://query.json \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-01T01:00:00Z \
  --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

<!-- TODO: known-useful namespaces/dimensions for this account, e.g.
AWS/RDS (CPUUtilization, DatabaseConnections, FreeableMemory,
ReadIOPS/WriteIOPS, ReplicaLag), AWS/ApplicationELB, custom app namespaces. -->

## Logs Insights

```bash
QUERY_ID=$(aws logs start-query \
  --log-group-name "<log-group>" \
  --start-time <epoch-seconds> --end-time <epoch-seconds> \
  --query-string 'fields @timestamp, @message | filter @message like /ERROR/ | sort @timestamp desc | limit 50' \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" --query 'queryId' --output text)

aws logs get-query-results --query-id "$QUERY_ID" --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

<!-- TODO: which log groups matter for which service, and any
query-string patterns that have been useful in past investigations. -->

## Alarms

```bash
aws cloudwatch describe-alarms --state-value ALARM --profile "$AWS_PROFILE" --region "$AWS_REGION"
```
