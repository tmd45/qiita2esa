# frozen_string_literal: true

require 'esa'
require 'json'
require 'pp'
require 'csv'
require 'set'

class ArticleImporter
  def initialize(esa_client, data_dir, qiita_access_token)
    @client = esa_client
    @category = data_dir
    @data_files = Dir.glob('./data/' + data_dir + '/*.json').sort
    @results_file_path = File.path('./results/' + data_dir + '.tsv')
    @images_file_path = File.path('./results/' + data_dir + '_images.tsv')
    @members = File.open('./data/members.txt').readlines.map(&:chomp)
    # 画像取得用
    @qiita_access_token = qiita_access_token
  end

  attr_accessor :client,
                :category,
                :data_files,
                :results_file_path,
                :images_file_path,
                :members,
                :qiita_access_token

  # タイトルだけ投稿して記事 URL を決定する
  # Qiita:Team と esa の記事 URL 対応表を生成する
  def make_urls(dry_run: true)
    puts "####################### Begin #make_urls"

    # 結果記録ファイル Open
    File.open(results_file_path, 'w') do |result|
      # 対象ファイル読み込みループ
      data_files.each_with_index do |data_file, idx|
        article = JSON.parse(File.read(data_file))
        article_title = article['title'].gsub(/\//, '&#47;')

        # 投稿 params 組み立て
        # WIP 状態で記事は空, ユーザは 'esa_bot' 固定
        # NOTE: update 時に Owner のみ created_by の上書きが可能
        params = {
          name: article_title,
          category: "(unsorted)/#{category}",
          wip: true,
          message: '[skip notice] Import from Qiita:Team; Make URL',
          user: 'esa_bot',
          body_md: 'under construction!'
        }

        print "[#{Time.now}] index[#{idx}] #{article_title} => "

        if dry_run
          puts "dry_run..."
          # DEBUG: 仮の値を吐き出しておく
          result.puts "#{idx}\t#{article['id']}\t#{sprintf('%06d', idx)}\t#{article['url']}\tNEW_ESA_URL\tNEW_ESA_TITLE"
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

        qiita_id = article['id']
        qiita_url = article['url']
        esa_id = response&.body['number'] || ''
        esa_url = response&.body['url'] || ''
        esa_title = response&.body['full_name'] || ''

        # 結果記録ファイルに出力
        result.puts "#{idx}\t#{qiita_id}\t#{esa_id}\t#{qiita_url}\t#{esa_url}\t#{esa_title}"
      end # of data_files.each_with_index
    end
    puts
  end

  # Qiita 記事本文から画像 URL を取得し、その画像を esa にアップロードする
  # Qiita 画像 URL と esa 画像 URL の対応表を生成する
  # NOTE: 添付されているのは画像だけじゃないが、面倒なので画像ってことにしておく
  def upload_images(dry_run: true)
    puts "####################### Begin #upload_images"

    # 重複のない元画像 URL 一覧を作成する
    image_paths_all = []
    image_paths = []

    # 対象記事ファイル読み込みループ
    data_files.each_with_index do |data_file, idx|
      article = JSON.parse(File.read(data_file))

      # 旧画像 URL の処理
      exp1 = /https:\/\/qiita-image-store.s3.amazonaws.com\/[0-9]+\/[0-9]+\/[\w\-]+\.[a-z]+/
      image_paths = image_paths + article['body'].scan(exp1)

      # 新画像 URL の処理（アクセスにログインセッションが必要）
      exp2 = /https:\/\/feedforce.qiita.com\/files\/[\w\-]+\.[a-z]+/
      image_paths = image_paths + article['body'].scan(exp2)

      image_paths.uniq!
      image_paths.sort!
      image_paths_all = image_paths_all + image_paths
    end # of data_files.each_with_index

    # 重複した URL は除外
    image_paths_all.uniq!

    # 結果記録ファイル Open
    File.open(images_file_path, 'w') do |result|
      # 画像を取得して esa にアップロードする
      image_paths_all.each_with_index do |image_path, idx|
        print "[#{Time.now}] index[#{idx}] #{image_path} => "

        if dry_run
          puts "dry_run..."
          # DEBUG: 仮の値を吐き出しておく
          result.puts "#{idx}\t#{image_path}\tNEW_ESA_IMAGE_URL"
          next
        end

        if image_path.include?('amazonaws')
          # 無条件にアップロード可能
          response = client.upload_attachment(image_path)
        else
          # 画像アクセスに認証情報が必要
          headers = { 'Authorization' => "Bearer #{qiita_access_token}" }
          response = client.upload_attachment([image_path, headers])
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
      end # of image_paths.each_with_index
    end
    puts
  end

  # 記事本文＋コメントをいろいろ変換しながら更新
  def update_post(dry_run: true)
    puts "####################### Begin #update_post"

    # 変換結果をキャッシュ
    # 記事 URL
    options = {
      col_sep: "\t",
      headers: [:idx, :qiita_id, :esa_id, :qiita_url, :esa_url, :esa_title]
    }
    # CSV::Table
    posts_table = CSV.read(results_file_path, options)

    # 画像 URL
    options = {
      col_sep: "\t",
      headers: [:idx, :qiita_image_url, :esa_image_url]
    }
    images_table = CSV.read(images_file_path, options)

    # 実在メンバー一覧
    members_set = Set.new(members) # Set 利用で検索効率を上げるハズ

    # 対象ファイル読み込みループ
    data_files.each_with_index do |data_file, idx|
      article = JSON.parse(File.read(data_file))

      # オリジナル記事 URL
      qiita_url = article['url']
      # オリジナル記事内容
      origin_body = article['body'] # Markdown
      # 記事作成者
      screen_name = article['user']['id'].downcase

      # esa の記事 ID を取得
      esa_id = posts_table.find { |row| row[:qiita_url] == qiita_url }&.send(:[], :esa_id)

      # 変換1
      #   Qiita URL の変換対応表 Hash を作成 → 記事置換
      keys = posts_table[:qiita_url]
      vals = posts_table[:esa_url]
      url_pairs = Hash[keys.zip(vals)]
      url_exp = /https:\/\/feedforce.qiita.com\/[\w\-]+\/items\/\w+/
      tmp1_body = origin_body.gsub(url_exp) { url_pairs[$&] || $& }

      # 変換2
      #   Qiita 画像 URL の変換対応表 Hash を作成 → 記事置換
      keys = images_table[:qiita_image_url]
      vals = images_table[:esa_image_url]
      url_pairs = Hash[keys.zip(vals)]
      images_exp = /https:\/\/feedforce.qiita.com\/files\/[\w\-]+\.[a-z]+|https:\/\/qiita-image-store.s3.amazonaws.com\/[0-9]+\/[0-9]+\/[\w\-]+\.[a-z]+/
      tmp2_body = tmp1_body.gsub(images_exp) { url_pairs[$&] || $& }

      # 変換3
      #   記事中のユーザーメンションっぽいやつを全部小文字にする（雑）
      replaced_body = tmp2_body.gsub(/\@[a-zA-Z0-9_-]+/) { $&.downcase }

      if dry_run
        puts "***** index: #{idx} *****"
        puts "Qiita URL: #{qiita_url}, esa ID: #{esa_id}"
        next
      end

      # 上書きする記事情報を構築
      params = {
        body_md: <<~BODY_MD,
          origin_created_at: #{article['created_at']}
          origin_qiita_url: #{qiita_url}

          #{replaced_body}
        BODY_MD
        wip: false,
        message: '[skip notice] Import from Qiita:Team; Update content',
        user: members_set.include?(screen_name) ? screen_name : 'esa_bot'
      }

      print "[#{Time.now}] index[#{index}] #{article['name']} => "
      response = client.update_post(esa_id, params)

      case response.status
      when 201
        esa_url = response.body['url']
        record_urls(qiita_url, esa_url)
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

      # 記事コメントを追加する

    end # of data_files.each_with_index

    puts
  end
end

#### Main #################################################

esa_client = Esa::Client.new(
  access_token: ENV['ESA_ACCESS_TOKEN'],
  current_team: ENV['ESA_CURRENT_TEAM']
)

qiita_access_token = ENV['QIITA_ACCESS_TOKEN']

importer = ArticleImporter.new(esa_client, ENV['GROUP_NAME'], qiita_access_token)
importer.make_urls(dry_run: true)
importer.upload_images(dry_run: true)
importer.update_post(dry_run: true)
