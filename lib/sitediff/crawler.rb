require 'sitediff/uriwrapper'
require 'typhoeus'

class SiteDiff
class Crawler
  DEFAULT_DEPTH = 3

  # Create a crawler with a base URL
  def initialize(base)
    @wrapper = UriWrapper.new(base)
    @base = URI(base)
  end

  # Generate a hydra
  def hydra
    Typhoeus::Hydra.new(max_concurrency: 10)
  end

  def crawl(depth = DEFAULT_DEPTH)
    @found = {}
    @hydra = hydra
    found('/', depth)
    @hydra.run
    return @found
  end

  # Handle a newly found relative URI
  def found(rel, depth)
    return if @found.include? rel
    @found[rel] = nil
    return if depth <= 0

    wrapper = @wrapper + rel
    wrapper.queue(@hydra) do |res|
      fetched(rel, depth, res)
    end
  end

  # Handle the fetch of a URI
  def fetched(rel, depth, res)
    return unless res.content # Ignore errors
    @found[rel] = res.content

    base = URI(@base) + rel

    doc = Nokogiri::HTML(res.content)
    links = find_links(doc)
    uris = links.map { |l| base + l }
    uris = filter_links(uris)

    # Make them relative
    rels = uris.map { |u| u.path.slice(@base.path.length, u.path.length) }

    # Queue them in turn
    rels.each do |r|
      next if @found.include? r
      found(r, depth - 1)
    end
  end

  # Return a list of string links found on a page.
  def find_links(doc)
    return doc.xpath('//a[@href]').map { |e| e['href'] }
  end

  # Filter out links we don't want. Links passed in are absolute URIs.
  def filter_links(uris)
    uris.find_all do |u|
      u.host == @base.host && u.path.start_with?(@base.path)
    end
  end
end
end
