# Jev (TypeSafe System One) を呼ぶ最小クライアント。標準ライブラリだけで動く。
require "net/http"
require "json"

# .env があれば読み込む（KEY=VALUE 形式のみ）
env_file = File.join(__dir__, ".env")
File.foreach(env_file) { |l| k, v = l.strip.split("=", 2); ENV[k] ||= v if v } if File.exist?(env_file)

class Jev
  URL = URI("https://api.typesafe.ai/v1/systemone")

  def initialize(model: "jev-latest")
    @model = model
    @key = ENV.fetch("TYPESAFE_API_KEY") { abort "TYPESAFE_API_KEY を .env に設定してください" }
    # 接続を使い回す（毎回TLS接続し直すと遅くなるため）
    # 既定では2秒使わないと張り直すので、間があく使い方でも保つよう延ばす
    @http = Net::HTTP.start(URL.host, URL.port, use_ssl: true, keep_alive_timeout: 120)
  end

  # state（文字列でもHashでもよい）と質問をまとめて送り、回答のHashを返す
  def ask(state, questions)
    req = Net::HTTP::Post.new(URL, "Authorization" => "Bearer #{@key}", "Content-Type" => "application/json")
    req.body = { model: @model, state:, questions: }.to_json
    res = begin
      @http.request(req)
    rescue EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError
      # 放置中にサーバー側から切られていたら、1回だけ張り直して送り直す
      @http.finish if @http.started?
      @http.start
      @http.request(req)
    end
    raise "HTTP #{res.code}: #{res.body[0, 200]}" unless res.is_a?(Net::HTTPSuccess)
    JSON.parse(res.body)
  end
end
