require "json"
require "fileutils"
require "open3"

# Builds fake browser profiles in a tmpdir — never a real one. Each
# profile also gets the credential/cookie/autofill decoys a real profile
# has (DECOYS), full of a sentinel string, so a spec can prove nothing but
# the allowed files is ever opened.
module BrowserImportFixtures
  SENTINEL = "DECOY-SECRET-NEVER-READ".freeze

  DECOYS = {
    "chromium" => ["Login Data", "Login Data-journal", "Cookies", "Web Data", "Network/Cookies", "Preferences",
                   "Local Storage/leveldb/000003.log"],
    "firefox" => %w[logins.json key4.db cookies.sqlite formhistory.sqlite cert9.db prefs.js]
  }.freeze

  def sqlite_available? = system("command -v sqlite3 > /dev/null 2>&1")

  def plutil_available? = system("command -v plutil > /dev/null 2>&1")

  def sqlite!(path, sql)
    FileUtils.mkdir_p(File.dirname(path))
    _out, err, status = Open3.capture3("sqlite3", path, sql)
    raise "sqlite3 fixture failed: #{err}" unless status.success?
  end

  def write_decoys(dir, family)
    DECOYS.fetch(family).each do |name|
      path = File.join(dir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, SENTINEL)
    end
  end

  def sql_quote(text) = "'#{text.to_s.gsub("'", "''")}'"

  # @param visits [Array<Hash>] url:, title:, visits:, days_ago:
  def chrome_profile(root, name: "Default", visits: [], bookmarks: nil, now: Time.now)
    dir = File.join(root, name)
    rows = visits.map do |v|
      at = ((now.to_i - (v.fetch(:days_ago, 1) * 86_400)) + 11_644_473_600) * 1_000_000
      "(#{sql_quote(v[:url])}, #{sql_quote(v[:title])}, #{v.fetch(:visits, 1)}, #{at})"
    end
    insert = rows.empty? ? "" : "INSERT INTO urls (url, title, visit_count, last_visit_time) VALUES #{rows.join(', ')};"
    sqlite!(File.join(dir, "History"), "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, " \
                                       "visit_count INTEGER, last_visit_time INTEGER); #{insert}")
    File.write(File.join(dir, "Bookmarks"), JSON.generate(bookmarks)) if bookmarks
    write_decoys(dir, "chromium")
    dir
  end

  def chrome_bookmarks(folders)
    children = folders.map do |folder, urls|
      { "type" => "folder", "name" => folder,
        "children" => urls.map { |url, title| { "type" => "url", "url" => url, "name" => title } } }
    end
    { "roots" => { "bookmark_bar" => { "type" => "folder", "name" => "Bookmarks bar", "children" => children },
                   "other" => { "type" => "folder", "name" => "Other", "children" => [] } } }
  end

  FIREFOX_SCHEMA = "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, " \
                   "last_visit_date INTEGER); CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, " \
                   "fk INTEGER, parent INTEGER, title TEXT); " \
                   "INSERT INTO moz_bookmarks VALUES (2, 2, NULL, 1, 'Gear');".freeze

  # @param bookmarks [Array<(Integer, String)>] moz_places id => bookmark
  #   title, filed under a "Gear" folder.
  def firefox_profile(root, visits: [], bookmarks: [], now: Time.now)
    dir = File.join(root, "Profiles", "abcd.default-release")
    inserts = { "moz_places" => firefox_places(visits, now), "moz_bookmarks" => firefox_marks(bookmarks) }
    sql = inserts.reject { |_t, rows| rows.empty? }.map { |t, rows| "INSERT INTO #{t} VALUES #{rows.join(', ')};" }
    sqlite!(File.join(dir, "places.sqlite"), "#{FIREFOX_SCHEMA} #{sql.join(' ')}")
    write_decoys(dir, "firefox")
    dir
  end

  def firefox_places(visits, now)
    visits.each_with_index.map do |v, i|
      at = (now.to_i - (v.fetch(:days_ago, 1) * 86_400)) * 1_000_000
      "(#{i + 1}, #{sql_quote(v[:url])}, #{sql_quote(v[:title])}, #{v.fetch(:visits, 1)}, #{at})"
    end
  end

  def firefox_marks(bookmarks)
    bookmarks.each_with_index.map { |(place_id, title), i| "(#{i + 10}, 1, #{place_id}, 2, #{sql_quote(title)})" }
  end

  # Every path under `root` any of Ruby's file-reading, copying, listing or
  # subprocess entry points was handed while the block ran. Wrapping each
  # one (rather than trusting the code under test to go through a seam)
  # means a stray File.read/FileUtils.cp/Dir.glob of a decoy anywhere in
  # the import path shows up here.
  def paths_touched_under(root)
    touched = []
    record = ->(*args) { args.flatten.each { |a| touched << a.to_s if a.is_a?(String) && a.start_with?(root) } }
    [[File, :open], [File, :new], [File, :read], [File, :binread], [File, :readlines], [File, :foreach],
     [IO, :read], [IO, :binread], [IO, :readlines], [IO, :copy_stream], [FileUtils, :cp], [FileUtils, :copy_file],
     [FileUtils, :cp_r], [Dir, :glob], [Dir, :children], [Dir, :entries], [Dir, :each_child], [Dir, :foreach],
     [Open3, :capture3], [Open3, :capture2], [Open3, :capture2e], [Open3, :popen3]].each do |klass, meth|
      allow(klass).to receive(meth).and_wrap_original do |original, *args, **kwargs, &block|
        record.call(*args)
        original.call(*args, **kwargs, &block)
      end
    end
    yield
    touched.uniq
  end
end
