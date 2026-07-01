#!/usr/bin/env bash
# Print Spaceship DNS (authoritative) + EKS LB targets for engress.io cutover table.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=deploy/lib/spaceship.sh
source "$ROOT/deploy/lib/spaceship.sh"

DOMAIN="${ENGRESS_DNS_DOMAIN:-engress.io}"
CLUSTER="${ENGRESS_DEPLOY_EKS_CLUSTER:-engress-east}"
REGION="${AWS_REGION:-us-east-2}"
GA_IPS="${ENGRESS_GA_IPS:-}"

normalize_ip_csv() {
  echo "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -E '^[0-9]+\.' | sort -u | paste -sd, -
}

ga_ips_match() {
  local cur="$1" want="$2"
  [[ "$(normalize_ip_csv "$cur")" == "$(normalize_ip_csv "$want")" ]]
}


spaceship_records() {
  spaceship_load_credentials "$REGION" || return 1
  spaceship_get_records "$DOMAIN"
}

eks_targets() {
  local core_alb="" edge_alb="" nlb=""
  if command -v kubectl >/dev/null 2>&1 && command -v aws >/dev/null 2>&1; then
    aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 || true
    core_alb="$(kubectl get ingress engress-core -n engress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    edge_alb="$(kubectl get ingress engress-edge -n engress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    nlb="$(kubectl get svc engress-edge-nlb -n engress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [[ -z "$nlb" ]]; then
      nlb="$(aws elbv2 describe-load-balancers --region "$REGION" \
        --query 'LoadBalancers[?Type==`network`].[DNSName]' --output text 2>/dev/null | head -1 || true)"
    fi
    if [[ -z "$core_alb" || -z "$edge_alb" ]]; then
      while read -r dns; do
        [[ -z "$dns" ]] && continue
        if [[ "$dns" == *"core"* || "$dns" == *"engressco"* ]]; then
          core_alb="${core_alb:-$dns}"
        elif [[ "$dns" == *"edge"* || "$dns" == *"engressed"* ]]; then
          edge_alb="${edge_alb:-$dns}"
        fi
      done < <(aws elbv2 describe-load-balancers --region "$REGION" \
        --query 'LoadBalancers[?Type==`application`].DNSName' --output text 2>/dev/null || true)
    fi
  fi
  printf '%s\n' "$core_alb" "$edge_alb" "$nlb"
}

lookup_spaceship() {
  local json="$1" name="$2" type="$3"
  jq -r --arg n "$name" --arg t "$type" '
    [.items[]? | select((.name // "") == $n and (.type // "") == $t)]
    | map(if .address then .address elif .cname then .cname else empty end)
    | unique | if length == 0 then "—" else join(", ") end
  ' <<<"$json"
}

lookup_spaceship_name() {
  local json="$1" name="$2"
  jq -r --arg n "$name" '
    [.items[]? | select((.name // "") == $n)]
    | map("\(.type): " + (if .address then .address elif .cname then .cname else "-" end))
    | unique | if length == 0 then "—" else join("; ") end
  ' <<<"$json"
}

public_dns() {
  local name="$1" type="$2"
  local fqdn
  if [[ "$name" == "@" ]]; then fqdn="$DOMAIN"; else fqdn="${name}.${DOMAIN}"; fi
  case "$type" in
    A) dig @8.8.8.8 +short "$fqdn" A 2>/dev/null | paste -sd, - ;;
    CNAME|ALIAS) dig @8.8.8.8 +short "$fqdn" CNAME 2>/dev/null | tr -d '\n' ;;
    *) dig @8.8.8.8 +short "$fqdn" 2>/dev/null | paste -sd, - ;;
  esac
}

echo "=== engress.io DNS cutover audit ($(date -u +%Y-%m-%dT%H:%MZ)) ==="
echo

ss_json=""
ss_err=""
if ss_json="$(spaceship_records 2>&1)"; then
  if jq -e '.items' >/dev/null 2>&1 <<<"$ss_json"; then
    echo "### Current Spaceship records (authoritative)"
    echo
    echo '```'
    jq -r '.items[]? | "\(.type)\t\(.name)\t\(.address // .cname // "-")\tTTL \(.ttl // "-")"' <<<"$ss_json" | sort
    echo '```'
    echo
  else
    ss_err="$ss_json"
    ss_json='{"items":[]}'
  fi
else
  ss_err="${ss_json:-Spaceship credentials missing}"
  ss_json='{"items":[]}'
fi

if [[ -n "$ss_err" ]]; then
  echo "WARN: Spaceship API not available — using public DNS (8.8.8.8) only."
  echo "      ${ss_err}"
  echo "      Set SPACESHIP_API_KEY/SPACESHIP_API_SECRET or SPACESHIP_API/SPACESHIP_SECRET."
  echo
fi

# macOS ships Bash 3.2 (no mapfile).
{
  read -r CORE_ALB || CORE_ALB=""
  read -r EDGE_ALB || EDGE_ALB=""
  read -r NLB || NLB=""
} < <(eks_targets)

if [[ -z "$GA_IPS" ]] && command -v aws >/dev/null; then
  GA_IPS="$(aws ssm get-parameter --name engress-deploy-global-accelerator-ips --region us-east-2 \
    --query Parameter.Value --output text 2>/dev/null || true)"
fi
if [[ -z "$GA_IPS" || "$GA_IPS" == "None" ]]; then
  GA_TARGET=""
else
  GA_TARGET="$GA_IPS (Global Accelerator anycast A records)"
fi

pending() { echo "**NOT READY YET**"; }

echo "### Cutover table (what to set in Spaceship)"
echo
printf '| Spaceship Name | Type | Current value | Set to (EKS target) | Change? |\n'
printf '|----------------|------|---------------|----------------------|--------|\n'

emit_row() {
  local name="$1" type="$2" change="$3" target_override="${4:-}"
  local cur tgt action
  cur="$(lookup_spaceship "$ss_json" "$name" "$type")"
  if [[ "$cur" == "—" && "$type" == "CNAME" ]]; then
    cur="$(lookup_spaceship_name "$ss_json" "$name")"
  fi
  if [[ "$cur" == "—" ]]; then
    cur="$(public_dns "$name" "$type")"
    cur="${cur:-—}"
  fi
  if [[ "$change" == "no" ]]; then
    tgt="$cur"
    action="keep"
  else
    case "$name" in
      edge-origin) tgt="${target_override:-${EDGE_ALB:-$(pending)}}" ;;
      core-origin) tgt="${target_override:-${CORE_ALB:-$(pending)}}" ;;
      '*.edge')
        if [[ -n "$GA_TARGET" ]]; then
          tgt="${target_override:-$GA_TARGET}"
        else
          tgt="${target_override:-${NLB:-$(pending)}}"
        fi
        ;;
      *) tgt="$cur" ;;
    esac
    if [[ "$tgt" == "**NOT READY YET**" ]]; then
      if [[ "$name" == "*.edge" && -n "$GA_IPS" && "$cur" != "—" ]]; then
        local ip ok=1
        IFS=',' read -ra _ga <<< "$GA_IPS"
        for ip in "${_ga[@]}"; do
          [[ -n "$ip" && "$cur" == *"$ip"* ]] || ok=0
        done
        if [[ "$ok" -eq 1 ]]; then
          action="keep"
          tgt="$cur"
        else
          action="wait for EKS LB"
        fi
      elif [[ "$name" == "*.edge" && "$cur" != "—" && "$cur" != *"elb"* && "$cur" == *,* ]]; then
        action="keep"
        tgt="$cur"
      elif [[ "$name" == "edge-origin" || "$name" == "core-origin" ]] && [[ "$cur" == *".elb."* ]]; then
        action="keep"
        tgt="$cur"
      else
        action="wait for EKS LB"
      fi
    elif [[ "$cur" == "$tgt" ]]; then
      action="keep"
    elif [[ "$name" == "*.edge" && -n "$GA_IPS" ]]; then
      if ga_ips_match "$cur" "$GA_IPS"; then
        action="keep"
        tgt="$cur"
      else
        action="UPDATE"
      fi
    else
      action="UPDATE"
    fi
  fi
  printf '| `%s` | %s | %s | %s | %s |\n' "$name" "$type" "$cur" "$tgt" "$action"
}

emit_row '@' 'ALIAS' 'no'
emit_row '@' 'CNAME' 'no'
emit_row 'www' 'CNAME' 'no'
emit_row 'get' 'CNAME' 'no'
emit_row 'downloads' 'CNAME' 'no'
emit_row 'edge-origin' 'CNAME' 'yes'
emit_row 'core-origin' 'CNAME' 'yes'
emit_row '*.edge' 'A' 'yes'

echo
echo "### After EKS LBs are ready — exact Spaceship PUT payloads"
echo
if [[ -n "$EDGE_ALB" && -n "$CORE_ALB" ]]; then
  jq -n \
    --arg edge "$EDGE_ALB" \
    --arg core "$CORE_ALB" \
    '{
      force: true,
      items: [
        {type:"CNAME", name:"edge-origin", cname:$edge, ttl:300},
        {type:"CNAME", name:"core-origin", cname:$core, ttl:300}
      ]
    }'
else
  echo "(waiting for ALB hostnames — run again after LBs provision)"
fi

if [[ -n "$GA_TARGET" ]]; then
  echo
  echo "### Global Accelerator (P03 target for edge wildcard)"
  echo
  echo "Set edge wildcard A records to GA anycast IPs:"
  IFS=',' read -ra _ga_ips <<< "$GA_IPS"
  for ip in "${_ga_ips[@]}"; do
    echo "  A  (name: edge wildcard)  ${ip}  TTL 300"
  done
  echo
  echo "Apply:"
  echo "  ./scripts/agent/spaceship-dns.sh apply-ga"
fi

echo
echo "EKS LB hostnames:"
echo "  core-origin → ${CORE_ALB:-<pending>}"
echo "  edge-origin → ${EDGE_ALB:-<pending>}"
echo "  edge wildcard → ${GA_TARGET:-${NLB:-<pending>}}"
