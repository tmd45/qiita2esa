# frozen_string_literal: true

require 'esa'
require 'json'
require 'yaml'
require 'pp'

# Import to esa.io
class ProjectImporter
  def initialize(esa_client)
    @client = esa_client
    @members = File.open('./data/all_members.txt').readlines.map(&:chomp)
  end

  attr_accessor :client, :members

  def import(dry_run: true, start_index: 0)
    data_files = Dir.glob('./data/projects/*.json').sort

    # 実在メンバー一覧
    members_set = Set.new(members) # Set 利用で検索効率を上げるハズ

    File.open(File.path('./results/projects.tsv'), 'w') do |file|
      data_files.each_with_index do |data_file, index|
        next if index < start_index

        article = JSON.parse(File.read(data_file))

        # 記事作成者
        screen_name = article.dig('user', 'id')&.downcase
        # Qiita URL
        qiita_url = "https://#{ENV['QIITA_CURRENT_TEAM']}.qiita.com/projects/#{article['id']}"

        params = {
          name: article['name'],
          category: '(unsorted)/projects',
          body_md: <<~BODY_MD,
          created_at: #{article['created_at']}
          qiita_url: #{qiita_url}
          archived: #{article['archived']}

          #{article['body']}
          BODY_MD
          wip: false,
          message: '[skip notice] Imported from Qiita:Team',
          user: members_set.include?(screen_name) ? screen_name : 'esa_bot'
        }

        if dry_run
          puts "***** index: #{index} *****"
          puts "Qiita URL: #{qiita_url}"
          pp params
          puts
          next
        end

        print "[#{Time.now}] index[#{index}] #{article['name']} => "
        response = client.create_post(params)

        case response.status
        when 201
          esa_url = response.body['url']
          puts "created: #{response.body['full_name']}\t#{esa_url}"
        when 429
          retry_after = (response.headers['Retry-After'] || 20 * 60).to_i
          puts "rate limit exceeded: will retry after #{retry_after} seconds."
          wait_for(retry_after)
          redo
        else
          # 失敗しても中断はせずとりあえず結果を吐いて次のレコードへ
          puts "failure with status: #{response.status}"
          next
        end

        # 元の URL と esa アップロード後の画像 URL ペアを記録
        # idx は記事 idx なので連続することがある
        file.puts "#{index}\t#{qiita_url}\t#{esa_url}"
      end
    end
  end

  private

  def wait_for(seconds)
    (seconds / 10).times do
      print '.'
      sleep 10
    end
    puts
  end
end

esa_client = Esa::Client.new(
  access_token: ENV['ESA_ACCESS_TOKEN'],
  current_team: ENV['ESA_CURRENT_TEAM']
)

importer = ProjectImporter.new(esa_client)
importer.import(dry_run: true) # default: dry_run
