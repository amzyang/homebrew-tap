# typed: false
# frozen_string_literal: true

require "download_strategy"

# gsql 是私有仓库，Homebrew 匿名下载 Release 资源会 404。
# 本策略用 HOMEBREW_GITHUB_API_TOKEN 经 GitHub API 认证下载。
#
# 放在 lib/（Homebrew 不把此目录当作 formula 扫描），由 Formula/gsql.rb 顶部的
# `require_relative "../lib/custom_download_strategy"` 引入——须在 class 定义前 require，
# 这样 `url ..., using: GitHubPrivateRepositoryReleaseDownloadStrategy` 才能解析到顶层常量。
#
# Homebrew 5.1.14+ 在加载 Formula 阶段会擦除 token 类环境变量；`using:` 只捕获常量，
# 策略实例化与下载发生在环境恢复之后，故在下载时读取 token 是安全的。
class GitHubPrivateRepositoryReleaseDownloadStrategy < CurlDownloadStrategy
  require "utils/github"

  def initialize(url, name, version, **meta)
    super
    parse_url_pattern
  end

  def parse_url_pattern
    url_pattern = %r{https://github.com/([^/]+)/([^/]+)/releases/download/([^/]+)/(\S+)}
    unless @url =~ url_pattern
      raise CurlDownloadStrategyError, "Invalid URL pattern for GitHub Release: #{@url}"
    end

    _, @owner, @repo, @tag, @filename = *@url.match(url_pattern)
  end

  def download_url
    "https://api.github.com/repos/#{@owner}/#{@repo}/releases/assets/#{asset_id}"
  end

  private

  def _fetch(url:, resolved_url:, timeout:, **)
    token = ENV["HOMEBREW_GITHUB_API_TOKEN"]
    if token.nil? || token.empty?
      raise CurlDownloadStrategyError, "HOMEBREW_GITHUB_API_TOKEN is required to install gsql (private repo)."
    end

    curl_download download_url,
                  "--header", "Accept: application/octet-stream",
                  "--header", "Authorization: token #{token}",
                  to: temporary_path
  end

  def asset_id
    @asset_id ||= begin
      release = GitHub::API.open_rest("https://api.github.com/repos/#{@owner}/#{@repo}/releases/tags/#{@tag}")
      asset = release["assets"].find { |a| a["name"] == @filename }
      raise CurlDownloadStrategyError, "Asset #{@filename} not found in release #{@tag}" if asset.nil?

      asset["id"]
    end
  end
end
