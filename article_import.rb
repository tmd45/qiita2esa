# frozen_string_literal: true

require 'esa'
require 'json'
require 'pp'

class ArticleImporter
  def initialize(esa_client, data_dir, cookie)
    @client = esa_client
    @data_files = Dir.glob('./data/' + data_dir + '/*.json').sort
    @results_file_path = File.path('./results/' + data_dir + '.tsv')
    @images_file_path = File.path('./results/' + data_dir + '_images.tsv')
    @members = File.open('./data/members.txt').readlines.inject(&:chomp)
    @cookie = cookie
  end

  attr_accessor :client,
                :data_files,
                :results_file_path,
                :images_file_path,
                :members,
                :cookie

  # タイトルだけ投稿して記事 URL を決定する
  # Qiita:Team と esa の記事 URL 対応表を生成する
  def make_urls(dry_run: true)
    puts "####################### Begin #make_urls"

    # 結果記録ファイル Open
    File.open(results_file_path, 'w') do |result|
      # 対象ファイル読み込みループ
      data_files.each_with_index do |data_file, idx|
        article = JSON.parse(File.read(data_file))

        # 投稿 params 組み立て
        # WIP 状態で記事は空, ユーザは 'esa_bot' 固定
        # NOTE: update 時に Owner のみ created_by の上書きが可能
        params = {
          name: article['title'].gsub(/\//, '&#47;'), # 日付がカテゴリにならないように
          category: '(unsorted)',
          wip: true,
          message: '[skip notice] Import from Qiita:Team; Make URL',
          user: 'esa_bot',
          body_md: 'under construction!'
        }

        print "[#{Time.now}] index[#{idx}] #{article['name']} => "

        if dry_run
          puts "dry_run..."
          next
        end

        # 記事作成
        response = client.create_post(params)

        case response.status
        when 201
          puts "created: #{response.body['full_name']}\t#{esa_url}"
        when 429
          retry_after = (response.headers['Retry-After'] || 20 * 60).to_i
          puts "rate limit exceeded: will retry after #{retry_after} seconds."
          wait_for(retry_after)
          redo
        else
          # 失敗しても中断はせずとりあえず結果を吐いて次のレコードへ
          puts "failure with status: #{response.status}"
        end

        qiita_url = article['url']
        esa_url = response&.body['url'] || ''
        esa_title = response&.body['full_name'] || ''

        # 結果記録ファイルに出力
        result.puts "#{idx}\t#{qiita_url}\t#{esa_url}\t#{esa_title}"
      end # end of data_files.each_with_index
    end
  end

  # Qiita 記事本文から画像 URL を取得し、その画像を esa にアップロードする
  # Qiita 画像 URL と esa 画像 URL の対応表を生成する
  def upload_images(dry_run: true)
    puts "####################### Begin #upload_images"

    # 結果記録ファイル Open
    File.open(images_file_path, 'w') do |result|
      image_paths = []

      # 対象記事ファイル読み込みループ
      data_files.each_with_index do |data_file, idx|
        article = JSON.parse(File.read(data_file))

        # 各記事から画像 URL を抽出

        # 旧画像 URL の処理
        exp1 = /https:\/\/qiita-image-store.s3.amazonaws.com\/[0-9]+\/[0-9]+\/.+\.[a-z]+/
        image_paths = image_paths + article['body'].scan(exp1)
        
        # 新画像 URL の処理（アクセスにログインセッションが必要）
        exp2 = /https:\/\/feedforce.qiita.com\/files\/.+\.[a-z]+/
        image_paths = image_paths + article['body'].scan(exp2)

        image_paths.uniq!
        image_paths.sort!

        # 画像を取得して esa にアップロードする
        image_paths.each do |image_path|
          print "[#{Time.now}] index[#{idx}] #{image_path} => "

          if dry_run
            puts "dry_run..."
            next
          end

          if image_path.include?('amazonaws')
            # 無条件にアップロード可能
            response = client.upload_attachment(image_path)
          else
            # 画像アクセスにセッション（cookie）が必要
            response = client.upload_attachment([image_path, cookie])
          end

          case response.status
          when 201
            puts "created: #{response.body['attachment']['url']}"
          when 429
            retry_after = (response.headers['Retry-After'] || 20 * 60).to_i
            puts "rate limit exceeded: will retry after #{retry_after} seconds."
            wait_for(retry_after)
            redo
          else
            # 失敗しても中断はせずとりあえず結果を吐いて次のレコードへ
            puts "failure with status: #{response.status}"
          end

          qiita_image_url = image_path
          esa_image_url = response&.body&.dig('attachment', 'url') || ''

          # 元の URL と esa アップロード後の画像 URL ペアを記録
          # idx は記事 idx なので連続することがある
          result.puts "#{idx}\t#{qiita_image_url}\t#{esa_image_url}"
        end # end of image_paths.each
      end # end of data_files.each_with_index
    end
  end

  def update_post
    # URL 作成済みの記事を上書き
    # 1. 作成者を member に変更
    # 2. 本文中の Qiita:Team URL を可能な限り esa URL に変換
    # 3. 本文中の 画像 URL を esa の画像 URL に変換
    # 4. 本文中の User ID を小文字（ScreenName）に変換

    # screen_name = article['user']['id'].downcase
    # members.include?(screen_name) ? screen_name : 'esa_bot'
  end
end

#### Main #################################################

esa_client = Esa::Client.new(
  access_token: ENV['ESA_ACCESS_TOKEN'],
  current_team: ENV['ESA_CURRENT_TEAM']
)

qiita_cookie = ENV['QIITA_COOKIE']

importer = ArticleImporter.new(esa_client, '10th-anniversary', qiita_cookie)
importer.make_urls(dry_run: true)
importer.upload_images(dry_run: true)
