# CloudTrail から直近のイベントを取り出して data/events.jsonl に保存する。読み取りのみ。
#
#   ruby fetch.rb          # 直近2000件から「操作名＋実行者＋エラー」が重複しないものを新しい順に100件
#   ruby fetch.rb --raw    # 重複をまとめず、直近100件をそのまま
#
# 認証情報は AWS SDK の通常の探し方に従う（AWS_PROFILE=... で切り替え）。リージョンの既定は ap-northeast-1
require "aws-sdk-cloudtrail"
require "json"

LIMIT = 100
SCAN = 2000 # 重複をまとめる場合に遡る件数
raw = ARGV.include?("--raw")

ct = Aws::CloudTrail::Client.new(
  region: ENV.fetch("AWS_REGION", "ap-northeast-1"),
  retry_mode: "adaptive", max_attempts: 10, # LookupEvents は毎秒2回までなので再試行に任せる
)

picked = {}
scanned = 0
ct.lookup_events(max_results: 50).each_page do |page|
  page.events.each do |e|
    ev = JSON.parse(e.cloud_trail_event)
    scanned += 1
    who = ev.dig("userIdentity", "arn") || ev.dig("userIdentity", "invokedBy") || ev.dig("userIdentity", "type")
    key = raw ? ev["eventID"] : [ev["eventName"], who, ev["errorCode"]]
    picked[key] ||= ev
  end
  print "\r#{scanned}件を確認 / #{picked.size}件を採用"
  break if picked.size >= LIMIT || (!raw && scanned >= SCAN)
end

events = picked.values.first(LIMIT)
Dir.mkdir("data") unless Dir.exist?("data")
File.write("data/events.jsonl", events.map(&:to_json).join("\n") + "\n")
puts "\n#{events.size}件 → data/events.jsonl（#{events.last["eventTime"]} 〜 #{events.first["eventTime"]}）"
