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

# 1回のリクエストで6つの質問をまとめて聞く
QUESTIONS = {
  sentiment: {
    type: "choice",
    instructions: "What is the overall sentiment the customer expresses toward the company or product in this inquiry?",
    criteria: {
      positive: "Satisfied, thankful, or praising. No meaningful complaint.",
      neutral: "A factual question or request with no clear emotion either way.",
      negative: "Unhappy, frustrated, disappointed, anxious, or angry. Includes polite or sarcastic complaints.",
      mixed: "Clearly expresses both a positive and a negative feeling about different aspects.",
    },
  },
  emotion: {
    type: "choice",
    instructions: "Which emotion is most dominant in this customer inquiry?",
    criteria: {
      gratitude: "Thanks or appreciation",
      joy: "Delight or excitement",
      anger: "Anger or outrage",
      frustration: "Annoyance at repeated problems or slow service",
      disappointment: "Let down, expectations not met",
      anxiety: "Worry or fear about consequences",
      none: "No particular emotion, purely informational",
    },
  },
  anger: {
    type: "score",
    instructions: "How angry or hostile is the customer toward the company?",
    criteria: [
      "Not angry at all",
      "Mildly dissatisfied, still calm",
      "Clearly irritated or frustrated",
      "Very angry, hostile, or threatening to leave or escalate",
    ],
  },
  urgent: { type: "noul", instructions: "Does the customer need a response urgently or express time pressure?" },
  churn_risk: { type: "noul", instructions: "Does the customer indicate they may stop using or cancel the company's product or service because of dissatisfaction?" },
  sarcasm: { type: "noul", instructions: "Does the message use sarcasm or irony, saying something positive on the surface while meaning something negative?" },
}

# data/inquiries.jsonl を読み込む
def load_inquiries
  File.readlines(File.join(__dir__, "data/inquiries.jsonl"), chomp: true)
      .reject(&:empty?).map { JSON.parse(_1, symbolize_names: true) }
end
