#!/usr/bin/env bash
#
# describe_subnets.sh
#
# 概要:
#   AWSアカウント内に存在するサブネットの情報を取得し、CSVファイルに出力する。
#
# 前提条件:
#   - AWS CLI がインストール・設定済みであること（aws configure 済み）
#   - jq がインストールされていること
#   - 対象アカウントに対する ec2:DescribeSubnets の権限があること
#
# 使い方:
#   ./describe_subnets.sh [オプション]
#
#   オプションの詳細は -h / --help を参照。
#
#   例:
#     # デフォルト設定で出力（CIDR順にソート）
#     ./describe_subnets.sh
#
#     # 特定リージョンを指定し、VpcId順にソート
#     ./describe_subnets.sh -r ap-northeast-1 \
#       -f name,id,vpc,cidr,az -s vpc
#
#     # 名前に "public" を含むサブネットだけ抽出
#     ./describe_subnets.sh -g "public"
#
# 出力:
#   指定した --fields の順に列を並べたCSVファイル
#   （省略時のファイル名は YYYYmmdd_subnets.csv）。
#   デフォルトではCIDR順にソートして出力する。

set -euo pipefail

REGION=""
OUTPUT=""
FIELDS_OPT="name,id,vpc,cidr,az"
SORT_FIELD="cidr"
FILTER_PATTERN=""
FORCE=0

VALID_FIELDS="id name vpc cidr az blank"
VALID_SORT_FIELDS="id name vpc cidr az"

usage() {
  cat <<'EOF'
describe_subnets.sh

AWSアカウント内のサブネット情報を取得し、CSVに出力する。

使い方:
  ./describe_subnets.sh [オプション]

オプション:
  -r, --region REGION     対象リージョン（省略時はAWS CLI設定のリージョン）
  -o, --output FILE       出力CSVファイル名（省略時は YYYYmmdd_subnets.csv）
  -f, --fields FIELDS     出力する列と順序をカンマ区切りで指定
                          指定可能な値: id,name,vpc,cidr,az,blank
                          デフォルト: name,id,vpc,cidr,az
  -s, --sort FIELD        指定した列でソートする（--fieldsと同じ値の集合から選択、blankは不可）
                          デフォルト: cidr
  -g, --filter PATTERN    出力対象の列の値にPATTERN（正規表現、大文字小文字区別なし）を含む行のみ出力
      --force             出力ファイルが既に存在する場合でも上書きする
  -h, --help              ヘルプを表示
EOF
}

die() {
  echo "エラー: $1" >&2
  exit 1
}

is_valid_value() {
  local value="$1" list="$2"
  local v
  for v in $list; do
    [[ "$v" == "$value" ]] && return 0
  done
  return 1
}

require_arg() {
  # $1: option name (for error message), $2: remaining arg count
  [[ "$2" -ge 2 ]] || die "$1 には値を指定してください。"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region)
      require_arg "$1" "$#"
      REGION="$2"; shift 2 ;;
    --region=*)
      REGION="${1#*=}"; shift ;;
    -o|--output)
      require_arg "$1" "$#"
      OUTPUT="$2"; shift 2 ;;
    --output=*)
      OUTPUT="${1#*=}"; shift ;;
    -f|--fields)
      require_arg "$1" "$#"
      FIELDS_OPT="$2"; shift 2 ;;
    --fields=*)
      FIELDS_OPT="${1#*=}"; shift ;;
    -s|--sort)
      require_arg "$1" "$#"
      SORT_FIELD="$2"; shift 2 ;;
    --sort=*)
      SORT_FIELD="${1#*=}"; shift ;;
    -g|--filter)
      require_arg "$1" "$#"
      FILTER_PATTERN="$2"; shift 2 ;;
    --filter=*)
      FILTER_PATTERN="${1#*=}"; shift ;;
    --force)
      FORCE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "不明なオプションです: $1" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "aws cliが見つかりません。インストールしてください。"
command -v jq >/dev/null 2>&1 || die "jqが見つかりません。インストールしてください。"

IFS=',' read -ra FIELDS_ARR <<< "$FIELDS_OPT"
[[ ${#FIELDS_ARR[@]} -eq 0 ]] && die "--fields に少なくとも1つの列を指定してください。"
for f in "${FIELDS_ARR[@]}"; do
  is_valid_value "$f" "$VALID_FIELDS" || die "不正な --fields の値です: $f (指定可能: $VALID_FIELDS)"
done

if [[ -n "$SORT_FIELD" ]]; then
  is_valid_value "$SORT_FIELD" "$VALID_SORT_FIELDS" || die "不正な --sort の値です: $SORT_FIELD (指定可能: $VALID_SORT_FIELDS)"
fi

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="$(date +%Y%m%d)_subnets.csv"
fi

if [[ -e "$OUTPUT" && "$FORCE" -ne 1 ]]; then
  die "出力ファイルが既に存在します: $OUTPUT (上書きする場合は --force を指定してください)"
fi

FIELDS_JSON=$(printf '%s\n' "${FIELDS_ARR[@]}" | jq -R . | jq -s .)

AWS_ARGS=(ec2 describe-subnets)
[[ -n "$REGION" ]] && AWS_ARGS+=(--region "$REGION")

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

RAW_JSON="$WORKDIR/raw.json"
ROWS_JSON="$WORKDIR/rows.json"
FILTERED_JSON="$WORKDIR/filtered.json"
SORTED_JSON="$WORKDIR/sorted.json"

echo "サブネットを取得しています..." >&2
aws "${AWS_ARGS[@]}" --output json > "$RAW_JSON" \
  || die "aws ec2 describe-subnets の実行に失敗しました。"

# ---- サブネットを1行1エントリに変換する ----
jq '[
  .Subnets[] as $sn |
  {
    id: ($sn.SubnetId // ""),
    name: ((($sn.Tags // []) | map(select(.Key == "Name")) | first | .Value) // ""),
    vpc: ($sn.VpcId // ""),
    cidr: ($sn.CidrBlock // ""),
    az: ($sn.AvailabilityZone // "")
  }
]' "$RAW_JSON" > "$ROWS_JSON" || die "サブネット情報の変換に失敗しました。"

# ---- フィルター（--fieldsで選択した列の値のみを対象に判定する） ----
if [[ -n "$FILTER_PATTERN" ]]; then
  jq --arg q "$FILTER_PATTERN" --argjson fields "$FIELDS_JSON" '
    [ .[] | select(
        ( [ $fields[] as $f | if $f == "blank" then empty else (.[$f] // "" | tostring) end ]
          | join(" ")
          | test($q; "i")
        )
      ) ]
  ' "$ROWS_JSON" > "$FILTERED_JSON" \
    || die "フィルター処理に失敗しました。--filter の値が正しい正規表現か確認してください（( ) [ ] + * . などの記号はエスケープが必要な場合があります）。"
else
  cp "$ROWS_JSON" "$FILTERED_JSON"
fi

# ---- ソート ----
# cidrは文字列ソートだとオクテットの桁数がずれて数値順にならない
# （例: 10.0.10.0/24 が 10.0.2.0/24 より前に来る）ため、IPを数値化してソートする。
if [[ "$SORT_FIELD" == "cidr" ]]; then
  jq '
    def ip_num:
      ((capture("^(?<a>\\d+)\\.(?<b>\\d+)\\.(?<c>\\d+)\\.(?<d>\\d+)")) // null) as $m
      | if $m == null then null
        else (($m.a|tonumber)*16777216 + ($m.b|tonumber)*65536 + ($m.c|tonumber)*256 + ($m.d|tonumber))
        end;
    sort_by((.cidr // "") | ip_num // 4294967296)
  ' "$FILTERED_JSON" > "$SORTED_JSON" || die "ソート処理に失敗しました。"
elif [[ -n "$SORT_FIELD" ]]; then
  jq --arg sf "$SORT_FIELD" 'sort_by(.[$sf])' "$FILTERED_JSON" > "$SORTED_JSON" \
    || die "ソート処理に失敗しました。"
else
  cp "$FILTERED_JSON" "$SORTED_JSON"
fi

# ---- CSV出力 ----
jq -r --argjson fields "$FIELDS_JSON" '
  def field_label:
    if . == "id" then "SubnetId"
    elif . == "name" then "Nameタグ"
    elif . == "vpc" then "VpcId"
    elif . == "cidr" then "CIDR"
    elif . == "az" then "AZ"
    elif . == "blank" then ""
    else . end;
  ($fields | map(field_label)) as $header |
  ([$header] + (map([ $fields[] as $f | if $f == "blank" then "" else (.[$f] // "" | tostring) end ])))
  | .[] | @csv
' "$SORTED_JSON" > "$OUTPUT" || die "CSV出力に失敗しました。"

ROW_COUNT=$(jq 'length' "$SORTED_JSON")
echo "完了しました: $OUTPUT (${ROW_COUNT}行のサブネットを出力)" >&2
