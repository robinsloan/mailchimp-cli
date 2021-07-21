require "rubygems"
require "kramdown"
require "front_matter_parser"
require "yaml/store"
require "MailchimpMarketing"
require "roadie"

unless File.exist?("config.yaml")
  puts "You need to create a file called config.yaml that contains your Mailchimp API key and some other configuration info. Look in mailchimp.rb for a template."
  exit
end

# config.yaml template:
# ---
# api_key: "foo"
# list_id: "bar"
# data_center: "blee"
# from_name: "Frodo Baggins"
# reply_to: "frodo@well.com"

CONFIG = YAML.load_file("config.yaml")
API_KEY = CONFIG["api_key"]
LIST_ID = CONFIG["list_id"]
DATA_CENTER = CONFIG["data_center"]
FROM_NAME = CONFIG["from_name"]
REPLY_TO = CONFIG["reply_to"]

$db = YAML::Store.new "campaigns.yaml"
$client = MailchimpMarketing::Client.new
$client.set_config( { api_key: API_KEY, server: DATA_CENTER } )

$tag_ids = {}
tag_lookup = $client.lists.list_segments( LIST_ID )
tag_lookup["segments"].each do |segment|
  $tag_ids[segment["name"]] = segment["id"]
end

def update_tags
  $tag_ids.each do |tag_name, tag_id|
    $client.lists.update_segment( LIST_ID, tag_id, { "name" => tag_name } )
  end
end

def create_new_campaign( with_slug: )

  $db.transaction do
    if $db[with_slug] != nil
      puts "You already have a message with that slug!"
      return
    end
  end

  filename = "messages/#{with_slug}.md"

  unless File.exist?(filename)
    puts "There's no file at #{filename}..."
    return
  end

  parsed_content = FrontMatterParser::Parser.parse_file( filename )

  header = parsed_content.front_matter

  response = $client.campaigns.create(
    { "type"        =>   "regular",
      "recipients"  => { "list_id" => LIST_ID },
      "settings"    => { "subject_line" => header["subject_line"],
                         "title" => header["title"],
                         "preview_text" => header["preview"],
                         "from_name" => FROM_NAME,
                         "reply_to" => REPLY_TO,
                         "auto_footer" => false },
      "tracking"    => { "opens" => true,
                         "html_clicks" => true }
    } )

  campaign_id = response["id"]

  $db.transaction do
    unless $db[with_slug]
      $db[with_slug] = { "id" => campaign_id,
                         "subject_line" => header["subject_line"],
                         "title" => header["title"],
                         "preview_text" => header["preview"],
                         "created_at" => Time.now }
    end
  end

  update_campaign_content( with_slug: with_slug )

  return campaign_id
end

TEMPLATE_PATH = "template.html"
YIELD_STRING = "__YIELD__"

# I'm putting this here, rather than in the template, because Markdown has
# problems with the pipe character used in Mailchimp's special codes and
# this was the easiest way to solve the problem!

UNSUBSCRIBE_CONTENT_HTML = <<~HEREDOC
<hr/>
<p class="meta">You&rsquo;re receiving this message because you are a member in good standing of the <a href="https://society.robinsloan.com">Society of the Double Dagger</a>. I&rsquo;m Robin Sloan, author of the novels Sourdough and Mr. Penumbra&rsquo;s 24-Hour Bookstore.</p>
<p class="meta">You can <a href="*|UNSUB|*">unsubscribe from all emails</a> instantly.</p>
HEREDOC

UNSUBSCRIBE_CONTENT_TEXT = <<~HEREDOC
You're receiving this message because you are a member in good standing of the Society of the Double Dagger. I'm Robin Sloan, author of the novels Sourdough and Mr. Penumbra's 24-Hour Bookstore.

You can unsubscribe from all emails instantly: *|UNSUB|*
HEREDOC

def update_campaign_content( with_slug: )

  $db.transaction do
    unless $db[with_slug]
      puts "There's no campaign with that slug..."
      return
    end
  end

  filename = "messages/#{with_slug}.md"

  parsed_content = FrontMatterParser::Parser.parse_file(filename)
  header = parsed_content.front_matter

  to_tags = header["tags"]

  # By including this dummy condition, you force Mailchimp to dynamically
  # recalculate the segment each time, which is what you want; without it,
  # I found that Mailchimp would sometimes send to "stale" segments.
  # It's a bit gross, I know!

  dummy_condition = [{ "condition_type" => "TextMerge",
                       "field" => "HASH",
                       "op" => "is",
                       "value" => "foo"
                     }]

  segment_options = { "match" => "any",
                      "conditions" => dummy_condition + to_tags.map do |tag|
                        { "condition_type" => "StaticSegment",
                          "field" => "static_segment",
                          "op" => "static_is",
                          "value" => $tag_ids[tag]
                        }
                      end
                    }

  markdown_content = parsed_content.content
  html_content = Kramdown::Document.new(markdown_content).to_html

  template = File.open(TEMPLATE_PATH).read
  html_email = template.gsub(YIELD_STRING, html_content + UNSUBSCRIBE_CONTENT_HTML)

  document_to_be_inlined = Roadie::Document.new(html_email)
  inlined_html_email = document_to_be_inlined.transform
  inlined_html_email = inlined_html_email.gsub("%7C", "|") # come ON

  text_email = markdown_content.strip + "\n\n" + UNSUBSCRIBE_CONTENT_TEXT

  $db.transaction do
    if $db[with_slug]
      campaign_id = $db[with_slug]["id"]
      $client.campaigns.update( campaign_id,
        { "recipients" => { "list_id" => LIST_ID,
                            "segment_opts" => segment_options },
            "settings" => { "subject_line" => header["subject_line"],
                            "title" => header["title"],
                            "preview_text" => header["preview"],
                            "from_name" => FROM_NAME,
                            "reply_to" => REPLY_TO,
                            "auto_footer" => false },
            "tracking" => { "opens" => true,
                            "html_clicks" => true }
        } )

      $client.campaigns.set_content( campaign_id, {"html" => inlined_html_email, "plain_text" => text_email } )

      created_at = $db[with_slug]["created_at"]

      $db[with_slug] = { "id" => campaign_id,
                         "subject_line" => header["subject_line"],
                         "title" => header["title"],
                         "preview_text" => header["preview"],
                         "to_tags" => to_tags,
                         "created_at" => created_at,
                         "modified_at" => Time.now }
    end
  end

end

def test_campaign( with_slug:, to_email: )
  $db.transaction do
    if $db[with_slug]
      campaign_id = $db[with_slug]["id"]
      response = $client.campaigns.send_test_email( campaign_id,
                  { "test_emails" => [to_email],
                    "send_type" => "html" } )
      puts response
      puts "Sent test email!"
    else
      puts "There's no campaign with that slug..."
      return
    end
  end
end

def delete_campaign( with_slug: )
  $db.transaction do
    if $db[with_slug]
      campaign_id = $db[with_slug]["id"]
      $client.campaigns.remove(campaign_id)
      $db[with_slug] = nil
    else
      puts "There's no campaign with that slug..."
      return
    end
  end

  puts "Deleted campaign with slug #{with_slug}."
end

unless ARGV.length > 1
  puts "You need some arguments!"
  exit
end

slug = ARGV[0]

case ARGV[1]
when "create"
  id = create_new_campaign( with_slug: slug )
  puts "Created new campaign with slug #{slug} and id #{id}"
when "delete"
  delete_campaign( with_slug: slug )
when "update"
  id = update_campaign_content( with_slug: slug )
  puts "Updated campaign with slug #{slug}"
when "test"
  if ARGV[2]
    test_campaign( with_slug: slug, to_email: ARGV[2] )
  else
    test_campaign( with_slug: slug, to_email: "rsloan@gmail.com" )
  end
when "delete"
  delete_campaign( with_slug: slug )
when "send"
  puts "Sending from the command line is disabled. Go press the button in Mailchimp!"
else
  puts "That's not a valid command."
end