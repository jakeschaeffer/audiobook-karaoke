# Sourced by the scripts: exports scripts/local.env if it exists. Values already in the environment
# win, so `SMOKE_BOOK=<id> ./scripts/smoke-play.sh` still works.
if [ -f scripts/local.env ]; then
  while IFS= read -r line; do
    case "$line" in
      [A-Z_]*=*)
        name=${line%%=*}
        value=${line#*=}
        value=${value%%[[:space:]]#*}
        value=${value%"${value##*[![:space:]]}"}
        [ -n "${!name:-}" ] || export "$name=$value"
        ;;
    esac
  done <scripts/local.env
fi
