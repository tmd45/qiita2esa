# frozen_string_literal: true

require 'esa'
require 'json'
require 'yaml'
require 'pp'

# Import to esa.io
class ProjectImporter
  def initialize(esa_client)
    @client = esa_client
    @data_dir = ENV['DATA_DIR']
    @filename_prefix = ENV['QIITA_EXPORT_FILENAME_PREFIX']
    @filename_suffix = ENV['QIITA_EXPORT_FILENAME_SUFFIX']
    puts 'initialize'
  end

  attr_accessor :client,
                :data_dir,
                :filename_prefix,
                :filename_suffix,

  def import(dry_run: true, start_index: 0)
    exported_data = JSON.parse(File.read(filepath))

    exported_data.sort_by { |d| d['created_at'] }.each_with_index do |article, index|
      next if index < start_index

      qiita_url = "https://#{ENV['QIITA_CURRENT_TEAM']}.qiita.com/projects/#{article['id']}"

      params = {
        name: article['name'],
        category: '(no category)/Qiita Projects',
        body_md: <<~BODY_MD,
          created_at: #{article['created_at']}
          qiita_url: #{qiita_url}
          archived: #{article['archived']}

          #{article['body']}
        BODY_MD
        wip: false,
        message: '[skip notice] Imported from Qiita:Team',
        user: 'esa_bot' # don't specify user
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
        record_urls(qiita_url, esa_url)
        puts "created: #{response.body['full_name']}\t#{esa_url}"
      when 429
        retry_after = (response.headers['Retry-After'] || 20 * 60).to_i
        puts "rate limit exceeded: will retry after #{retry_after} seconds."
        wait_for(retry_after)
        redo
      else
        puts "failure with status: #{response.status}"
        exit 1
      end
    end
  end

  private

  # create file path
  def filepath
    File.path(data_dir + filename_prefix + 'projects' + filename_suffix)
  end

  # Qiita:Team と esa の記事 URL 対応表を作る
  def record_urls(qiita_url, esa_url)
    File.open(File.path(data_dir + 'record_urls.tsv'), 'a') do |file|
      file.puts "#{qiita_url}\t#{esa_url}"
    end
  end

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
importer.import(dry_run: false) # default: dry_run
