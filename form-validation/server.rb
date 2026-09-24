# ブラウザと Jev の間に立つ小さな中継サーバー。
# Jev API はブラウザからの直接呼び出し（CORS）を許可していないので、ここを経由する。
# APIキーはサーバー側にだけ置き、ブラウザには出さない。
#
#   ruby server.rb   → http://localhost:4567
require "rackup"
require_relative "jev"

INDEX = File.join(__dir__, "index.html")

# 起動時に Jev への接続を3本張っておき、使い回す（1回目からTLS接続の待ちが出ないように）
POOL = Queue.new
3.times { POOL << Jev.new }

app = lambda do |env|
  req = Rack::Request.new(env)
  case [req.request_method, req.path]
  in ["GET", "/"]
    [200, { "content-type" => "text/html; charset=utf-8" }, [File.read(INDEX)]]
  in ["POST", "/jev"]
    body = JSON.parse(req.body.read)
    jev = POOL.pop
    begin
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      answer = jev.ask(body["state"], body["questions"])
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    ensure
      POOL << jev
    end
    # Jev 自体にかかった時間をヘッダーで返し、ブラウザ側で往復時間と並べて表示する
    [200, { "content-type" => "application/json", "x-jev-ms" => ms.to_s }, [answer.to_json]]
  else
    [404, { "content-type" => "text/plain" }, ["not found"]]
  end
rescue => e
  [502, { "content-type" => "application/json" }, [{ error: e.message }.to_json]]
end

Rackup::Handler.get("puma").run(app, Host: "127.0.0.1", Port: 4567)
