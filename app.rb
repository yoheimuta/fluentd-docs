require 'rubygems'
require 'sinatra'
require 'sinatra/assetpack'
require 'haml'
require 'sass'
require 'coderay'
require 'indextank'
require 'rack/codehighlighter'
require 'json'
require 'time'

$LOAD_PATH << File.dirname(__FILE__) + '/lib'
require 'article.rb'
require 'term.rb'

# Airbrake
configure :production do
  require 'airbrake'
  Airbrake.configure do |config|
    config.api_key = `ENV['AIRBRAKE_API_KEY']`
  end
  use Airbrake::Rack
end

# NewRelic
configure :production do
  require 'newrelic_rpm'
end

# require 'rack/coderay'
# use Rack::Coderay, "//pre[@lang]>code"
use Rack::Codehighlighter, :coderay, :markdown => true, :element => "pre>code", :pattern => /\A:::(\w+)\s*(\n|&#x000A;)/i, :logging => false
configure :production do
  ENV['APP_ROOT'] ||= File.dirname(__FILE__)
end

set :app_file, __FILE__
set :static_cache_control, [:public, :max_age => 3600*24]

# In-Mem Cache
$IO_CACHE ||= {}
configure :production do
  if $IO_CACHE.empty?
    Dir.glob(["#{settings.root}/docs/*.txt", "#{settings.root}/docs/*/*.txt"]) { |path|
      $IO_CACHE[path] = File.read(path)
    }
  end
end

#
# For i18n
#
def build_available_languages
  articles = Dir.glob("#{settings.root}/docs/*.txt").map { |a|
    a["#{settings.root}/docs/".size..-(1 + ".txt".size)]
  }

  languages = {}
  articles.each { |article|
    langs = ['en']
    Dir.glob("#{settings.root}/docs/*/#{article}.txt").each { |a|
      # skipping versions
      unless /^v\d+/.match(a.split("/")[-2])
        langs << a["#{settings.root}/docs/".size..-(1 + 1 + "#{article}.txt".size)]
      end
    }
    languages[article] = langs.sort
  }
  languages
end
$AVAILABLE_LANGUAGES = build_available_languages
$DEFAULT_LANGUAGE = 'en'
$DEFAULT_VERSION = 'v0.12'

#
# For table-of-content
#
require 'toc'

def build_tocs
  toc_vers = Dir.glob("#{settings.root}/lib/toc.#{$DEFAULT_LANGUAGE}.*.rb").map { |toc|
    File.basename(toc, ".rb")["toc.#{$DEFAULT_LANGUAGE}.".size..-1]
  }

  tocs = {}
  toc_vers.each { |ver|
    tocs[ver] = TOC.new($DEFAULT_LANGUAGE, ver)
  }
  tocs
end
$TOCS = build_tocs

#
# Last update list for each article
#
$LAST_UPDATED = JSON.parse(File.read("#{settings.root}/config/last_updated.json"))

#
# Outdated span for translated articles
#
$OUTDATED_SPAN = 30 * 24 * 60 * 60

#
# NOT FOUND
#
not_found do
  erb :not_found
end

#
# Static Assets
# @see http://ricostacruz.com/sinatra-assetpack/
#
set :root, File.dirname(__FILE__)

unless ENV['RACK_ENV'] == 'test'
  Sinatra.register Sinatra::AssetPack
  assets {
    serve '/js',  from: 'app/js'  # Optional
    serve '/css', from: 'app/css' # Optional
    js :app, '/js/app.js', [
      '/js/*.js'
    ]
    css :application, '/css/application.css', [
      '/css/*.css'
    ]
    js_compression :yui
    css_compression :yui
    prebuild true # only on production
    expires 24*3600*7, :public
  }
end

#
# OLD URL REDIRECTS
#
get '/articles/architecture' do
  redirect 'http://www.fluentd.org/architecture', 301
end

get '/articles/users' do
  redirect 'http://www.fluentd.org/testimonials', 301
end

get '/articles/slides' do
  redirect 'http://www.fluentd.org/slides', 301
end

#
# PATHS
#
get '/' do
  redirect '/articles/quickstart', 301
end

get '/robots.txt' do
  content_type 'text/plain'
  "User-agent: *\nSitemap: /sitemap.xml\n"
end

get '/sitemap.xml' do
  @article_names = []
  $TOCS[$DEFAULT_VERSION].sections.each { |_, _, categories|
    categories.each { |_, _, articles|
      articles.each { |name, _, _|
        @article_names << name
      }
    }
  }

  content_type 'text/xml'
  erb :sitemap, :layout => false
end

get '/search' do
  page = params[:page].to_i
  search, prev_page, next_page = search_for(params[:q], page)
  erb :search, :locals => {:search => search, :query => params[:q], :prev_page => prev_page, :next_page => next_page}
end

get '/categories/:category' do
  redirect "/#{$DEFAULT_VERSION}/categories/#{params[:category]}", 301
end

get '/v0.10/categories/:category' do
  cache_long
  render_category params[:category], 'v0.10'
end

get '/v0.12/categories/:category' do
  cache_long
  render_category params[:category], 'v0.12'
end

get '/recipe/apache/:data_sink' do
  redirect "/recipe/apache-logs/#{params[:data_sink]}", 301
end

get '/recipe/:data_source/:data_sink' do
  params[:article] = "recipe-#{params[:data_source]}-to-#{params[:data_sink]}"
  puts "@[#{ENV['RACK_ENV']}.articles] #{{ :name => params[:article] }.to_json}"
  redirect "/articles/#{params[:article]}", 301
end

get '/articles/:article' do
  puts "@[#{ENV['RACK_ENV']}.articles] #{{ :name => params[:article] }.to_json}"
  cache_long
  render_article params[:article], params[:congrats]
end

# ver needs to come before /:lang/article/:article
# otherwise, lang matches first.

get '/v0.10/articles/:article' do
  puts "@[#{ENV['RACK_ENV']}.articles] #{{ :name => params[:article] }.to_json}"
  cache_long
  render_article params[:article], params[:congrats], ver: 'v0.10'
end

get '/v0.12/articles/:article' do
  puts "@[#{ENV['RACK_ENV']}.articles] #{{ :name => params[:article] }.to_json}"
  cache_long
  render_article params[:article], params[:congrats], ver: 'v0.12'
end

get '/:lang/articles/:article' do
  puts "@[#{ENV['RACK_ENV']}.articles] #{{ :name => params[:article] }.to_json}"
  redirect "/articles/#{params[:article]}", 301
end

helpers do
  def render_category(category, ver = $DEFAULT_VERSION)
    @articles = []
    @desc = ''
    sections(ver).each { |_, _, categories|
      categories.each { |name, title, articles|
        if name == category
          @title = title
          @articles = articles
          @desc = title
          break
        end
      }
    }

    if @articles.length == 1
      article_name = @articles.first.first
      redirect_path = if /^recipe-/.match(article_name)
                        article_name.split("-", 3).join("/")	
                      elsif ver == $DEFAULT_VERSION
                        "/articles/#{article_name}"
                      else
                        "/#{ver}/articles/#{article_name}"
                      end
      redirect redirect_path, 301
    elsif !@articles.empty?
      @articles
      erb :category
    else
      status 404
    end
  rescue Errno::ENOENT
    status 404
  end

  def render_article(article, congrats, lang: $DEFAULT_LANGUAGE, ver: $DEFAULT_VERSION)
    @filepath = article_file(article, lang, ver)
    @has_default_version = File.exists?(article_file(article, lang, $DEFAULT_VERSION))

    unless $IO_CACHE.has_key? @filepath
      $IO_CACHE[@filepath] = File.read(@filepath)
    end

    doc_path = File.dirname(@filepath)

    @article = Article.load(article, $IO_CACHE[@filepath], doc_path)
    @title   = @article.title
    @desc    = @article.desc
    @content = @article.content
    @intro   = @article.intro
    @toc     = @article.toc
    @body    = @article.body
    @congrats = congrats ? true : false
    @current_version = $DEFAULT_VERSION
    @article_version = ver
    @default_url = "/articles/#{article}"
    @last_updated = $LAST_UPDATED[lang][article]
    @available_langs = $AVAILABLE_LANGUAGES[article] || ['en'] # to support  new experimental articles

    erb :article
  end

  def article_file(article, lang, ver)
    if article.include?('/')
      article
    else
      path_prefix = "#{settings.root}/docs/"

      if ver != 'v0.10'
        path_prefix += "#{ver}/"
      end

      if lang != 'en'
        path_prefix += "#{lang}/"
      end

      path_prefix + article + ".txt"
    end
  end

  def prefix
    # currently, v0.12 docs only exists for English.
    # So, the prefix is either
    # 1. version/
    # 2. lang/
    @article_version ? "#{@article_version}/" : "" 
  end

  def avaiable_language?(article, lang)
    return true if lang == $DEFAULT_LANGUAGE
    return false unless $AVAILABLE_LANGUAGES.has_key?(article)

    $AVAILABLE_LANGUAGES[article].include?(lang)
  end

  def cache_long
    response['Cache-Control'] = "public, max-age=#{60 * 60 * 6}" unless development?
  end

  def slugify(title)
    title.downcase.gsub(/[^a-z0-9 -]/, '').gsub(/ /, '-')
  end

  def find_category(article, ver = $DEFAULT_VERSION)
    return nil if article.nil?
    sections(ver).each { |_, _, categories|
      categories.each { |category_name, _, articles|
        articles.each { |article_name, _, _|
          return category_name if article_name == article
        }
      }
    }
    nil
  end

  def find_keywords(article, category, ver = $DEFAULT_VERSION)
    default = ['Fluentd', 'log collector']
    sections(ver).each { |_, _, categories|
      categories.each { |category_name, _, articles|
        return default + [category_name] if category_name == category
        articles.each { |article_name, title, keywords|
          if article_name == article
            return default + [title] + keywords
          end
        }
      }
    }
    default
  end

  def sections(ver)
    v = ver.nil? ? $DEFAULT_VERSION : ver
    $TOCS[v].sections
  end

  def next_section(current_slug, root=sections($DEFAULT_VERSION))
    nil
  end

  def search_for(query, page = 0)
    client = IndexTank::Client.new(ENV['SEARCHIFY_API_URL'])
    index = client.indexes('td-docs')
    search = index.search(query, :start => page * 10, :len => 10, :fetch => 'title', :snippet => 'text')
    next_page =
        if search['matches'] > (page + 1) * 10
          page + 1
        end
    prev_page =
        if page > 0
          page - 1
        end
    [search, prev_page, next_page]
  end

  alias_method :h, :escape_html
end
