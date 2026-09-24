# 問い合わせ1000件を Jev で一括判定し、正解率と速度を集計する。
#
#   ruby analyze.rb
#
# 出力: results/results.jsonl（全件）, results/errors.jsonl（不正解のみ）
require_relative "jev"

CONCURRENCY = 10 # 同時リクエスト数

items = load_inquiries
queue = Queue.new
items.each { queue << _1 }
rows = []
lock = Mutex.new

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# 10本のスレッドがそれぞれ自分の接続でキューから1件ずつ取って判定する
CONCURRENCY.times.map do
  Thread.new do
    jev = Jev.new
    while (item = queue.pop(true) rescue nil)
      s0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        r = jev.ask(item[:text], QUESTIONS)
      rescue => e # 1件の失敗で全体を止めない
        lock.synchronize { rows << item.merge(error: e.message) }
        next
      end
      a = r["answers"]
      row = item.merge(
        pred: a["sentiment"]["choice"],
        sentiment_conf: a["sentiment"]["confidence"],
        sentiment_probs: a["sentiment"]["probabilities"],
        emotion: a["emotion"]["choice"],
        anger: a["anger"]["score"],
        urgent: a["urgent"]["noul"],
        churn_risk: a["churn_risk"]["noul"],
        sarcasm: a["sarcasm"]["noul"],
        latency_s: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - s0).round(3),
        input_tokens: r["usage"]["input_tokens"],
        model: r["model"],
      )
      lock.synchronize do
        rows << row
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        print "\r#{rows.size}/#{items.size}件  #{elapsed.round(1)}秒"
      end
    end
  end
end.each(&:join)

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
puts "\n全#{rows.size}件の処理時間: #{elapsed.round(1)}秒（#{(rows.size / elapsed).round(1)}件/秒）"

rows.sort_by! { _1[:id] }
Dir.mkdir("results") unless Dir.exist?("results")
File.write("results/results.jsonl", rows.map(&:to_json).join("\n") + "\n")

failed, rows = rows.partition { _1[:error] }
puts "!! API失敗 #{failed.size}件: #{failed.map { "##{_1[:id]}" }.join(", ")}" if failed.any?

def acc(label, sub)
  ok = sub.count { _1[:pred] == _1[:expected] }
  puts format("  %-12s %4d/%-4d = %5.1f%%", label, ok, sub.size, 100.0 * ok / sub.size) if sub.any?
end

puts "\n=== モデル: #{rows[0][:model]} / #{rows.size}件 ==="
acc "全体", rows
acc "普通の文", rows.reject { _1[:tricky] }
acc "難しい文", rows.select { _1[:tricky] }

lat = rows.map { _1[:latency_s] }.sort
puts "\n1件あたりの応答時間  中央値 #{lat[lat.size / 2]}秒 / 最大 #{lat[-1]}秒"
puts "入力トークン合計 #{rows.sum { _1[:input_tokens] }.to_s.reverse.scan(/\d{1,3}/).join(",").reverse}"

puts "\n確信度帯ごとの正解率"
[[0, 0.5], [0.5, 0.8], [0.8, 0.95], [0.95, 1.01]].each do |lo, hi|
  acc "#{lo}〜#{[hi, 1].min}", rows.select { (lo...hi).cover?(_1[:sentiment_conf]) }
end

wrong = rows.reject { _1[:pred] == _1[:expected] }
File.write("results/errors.jsonl", wrong.map { _1.to_json + "\n" }.join)
puts "\n不正解 #{wrong.size}件 → results/errors.jsonl"
wrong.group_by { [_1[:expected], _1[:pred]] }.sort_by { -_2.size }.each do |(e, p), rs|
  puts format("  想定 %-8s → 予測 %-8s %d件", e, p, rs.size)
end
