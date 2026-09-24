# CloudTrail のイベントを1件ずつ Jev に渡してリスクを評価する。
# イベントのJSONは加工せず、そのまま state として渡す。
#
#   ruby evaluate.rb                       # data/events.jsonl の全件
#   ruby evaluate.rb 10                    # 先頭10件だけ
#   ruby evaluate.rb data/other.jsonl      # 別のファイル
#   ruby evaluate.rb --mix                 # 架空の危険操作(samples/)をランダムな位置に混ぜる
require_relative "jev"

QUESTIONS = {
  risk: {
    type: "score",
    instructions: "How risky is this AWS CloudTrail event from a security perspective?",
    criteria: [
      "Routine read-only or automated activity with no security impact",
      "Normal configuration change with limited impact",
      "Security-relevant change or unusual activity worth reviewing",
      "High risk: privilege escalation, disabling security controls, public exposure, data destruction, or likely compromise",
    ],
  },
  category: {
    type: "choice",
    instructions: "What kind of activity is this CloudTrail event?",
    criteria: {
      read: "Listing, describing, or reading resources without changing them",
      change: "Ordinary creation or update of non-security resources",
      iam: "Changes to users, roles, policies, access keys, or permissions",
      security_control: "Changes to logging, monitoring, encryption, or security services (CloudTrail, GuardDuty, Config, KMS)",
      exposure: "Makes resources or data reachable from outside the account (public buckets, shared snapshots, open security groups)",
      destructive: "Deletes resources or data",
      auth: "Sign-in, session, or credential activity",
    },
  },
  human: { type: "noul", instructions: "Was this action performed directly by a human (console or CLI) rather than by an automated AWS service or tool?" },
  weakens: { type: "noul", instructions: "Does this action weaken security, such as disabling logging or protection, broadening access, or removing encryption?" },
  escalation: { type: "noul", instructions: "Could this action be used to escalate privileges or to gain persistent access to the account?" },
  investigate: { type: "noul", instructions: "Should a security engineer look into this event today?" },
}

file = ARGV.find { File.exist?(_1) } || "data/events.jsonl"
limit = ARGV.find { _1.match?(/\A\d+\z/) }&.to_i
events = File.readlines(file, chomp: true).reject(&:empty?).map { JSON.parse(_1) }
events = events.first(limit) if limit

# 架空のイベントには印を付けず（Jevへのヒントになるため）、Ruby側で覚えておく
planted = {}.compare_by_identity
if ARGV.include?("--mix")
  account = events.first["recipientAccountId"]
  { "samples/risky.jsonl" => "★", "samples/decoys.jsonl" => "☆" }.each do |path, mark|
    File.foreach(path) do |line|
      ev = JSON.parse(line.gsub("123456789012", account)) # アカウントIDを実データに揃える
      planted[ev] = mark
      events.insert(rand(events.size + 1), ev)
    end
  end
end

jev = Jev.new
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
t0 = clock.()

results = events.map.with_index(1) do |ev, i|
  s0 = clock.()
  a = jev.ask(ev, QUESTIONS)["answers"] # イベントのHashをそのまま渡す
  ms = ((clock.() - s0) * 1000).round

  risk = a["risk"]["score"]
  who = [ev.dig("userIdentity", "type") || "-", ev.dig("userIdentity", "userName")].compact.join(":")
  flags = %w[human weakens escalation investigate].select { a[_1]["noul"] >= 0.5 }
  bar = "█" * risk.round + "░" * (3 - risk.round)
  alert = risk >= 1.5 ? "🔴" : risk >= 0.5 ? "🟡" : "🟢"

  puts format("%3d %s %s %s %.1f  %-34s %-22s %-16s %4dms  %s",
              i, planted[ev] || " ", alert, bar, risk, ev["eventName"][0, 34], who[0, 22],
              a["category"]["choice"], ms, flags.join(" "))

  { event: ev, planted: planted[ev], risk:, category: a["category"]["choice"], flags:,
    nouls: a.slice(*%w[human weakens escalation investigate]).transform_values { _1["noul"] }, ms: }
end

total = clock.() - t0
ms = results.map { _1[:ms] }.sort
puts "\n#{results.size}件を #{total.round(1)}秒で評価（1件あたり 中央値 #{ms[ms.size / 2]}ms / 最大 #{ms[-1]}ms）"

puts "\nリスクの高い順 上位10件"
ranked = results.sort_by { -_1[:risk] }
ranked.first(10).each do |r|
  ev = r[:event]
  puts format("  %s %.2f  %-30s %-12s %s  %s", r[:planted] || " ", r[:risk], ev["eventName"], r[:category],
              ev["eventTime"], ev["errorCode"] ? "(#{ev["errorCode"]})" : "")
end

puts "\n種類別: " + results.map { _1[:category] }.tally.sort_by { -_2 }.map { "#{_1} #{_2}" }.join(" / ")
puts "今日見るべき(investigate): #{results.count { _1[:flags].include?("investigate") }}件"

if planted.any?
  rank = ->(mark) { ranked.each_index.select { ranked[_1][:planted] == mark }.map { _1 + 1 } }
  risky = rank.("★")
  puts "\n★ 架空の危険操作 #{risky.size}件 → 上位#{risky.size}件に入ったのは #{risky.count { _1 <= risky.size }}件（順位 #{risky.join(", ")}）"
  puts "☆ 似ているが安全な操作 #{planted.size - risky.size}件 → 順位 #{rank.("☆").join(", ")}"
end

Dir.mkdir("results") unless Dir.exist?("results")
File.write("results/results.jsonl", results.map(&:to_json).join("\n") + "\n")
puts "→ results/results.jsonl"
