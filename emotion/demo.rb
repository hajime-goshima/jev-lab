# Jev が問い合わせを1件ずつ判定する様子と、その速さを見るデモ。
#
#   ruby demo.rb                 # データからランダムに10件
#   ruby demo.rb 20              # ランダムに20件
#   ruby demo.rb "返金まだですか？"  # 好きな文を判定
require_relative "jev"

jev = Jev.new

texts =
  if ARGV.empty? || ARGV[0].match?(/\A\d+\z/)
    load_inquiries.sample((ARGV[0] || 10).to_i).map { [_1[:text], _1[:expected]] }
  else
    [[ARGV.join(" "), nil]]
  end

MARK = { "positive" => "😊", "neutral" => "😐", "negative" => "😠", "mixed" => "🤔" }

times = texts.map do |text, expected|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  a = jev.ask(text, QUESTIONS)["answers"]
  ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round

  s = a["sentiment"]
  flags = %w[urgent churn_risk sarcasm].select { a[_1]["noul"] >= 0.5 }
  check = expected && (s["choice"] == expected ? " ✅" : " ❌ 想定:#{expected}")

  puts "「#{text.gsub(/\s+/, " ")[0, 60]}#{"…" if text.size > 60}」(#{text.size}字)"
  puts "  #{MARK[s["choice"]]} #{s["choice"]} (確信度 #{s["confidence"]})#{check}" \
       "  感情:#{a["emotion"]["choice"]}  怒り:#{a["anger"]["score"].round(1)}/3" \
       "#{"  ⚑ #{flags.join(" ")}" unless flags.empty?}"
  puts "  ⏱  #{ms} ms", ""
  ms
end

if times.size > 1
  sorted = times.sort
  puts "#{times.size}件  中央値 #{sorted[sorted.size / 2]} ms / 最速 #{sorted[0]} ms / 最遅 #{sorted[-1]} ms"
end
