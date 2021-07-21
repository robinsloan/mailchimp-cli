# A minimalist Mailchimp CLI

I have not created a campaign by hand in Mailchimp in six months, instead happily managing them using this script, so I thought I'd share it.

Here's how it works. Start by drafting your email in `messages/`. The message's "slug" thereafter will be the filename before `.md`; the slug, for example, of the message included in this project is `2021-july`.

To create the campaign in Mailchimp:

`ruby mailchimp.rb 2021-july create`

Then, send a test email:

`ruby mailchimp.rb 2021-july test robin@robinsloan.com`

Spot an error? Edit the Markdown file, then update the campaign in Mailchimp:

`ruby mailchimp.rb 2021-july update`

You can also delete the campaign from Mailchimp (leaving the Markdown file intact, of course):

`ruby mailchimp.rb 2021-july delete`

That's it! There is currently no way to send from the command line, because the thought of making a mistake freaked me out too much. Better to log in, give everything a final look, and send from the Mailchimp website.

The template is in `template.html` and is presently very minimal. You can replace it, of course, with an HTML email template from elsewhere on Github or one of your own devising. Note the `__YIELD__`.

As you'll see, this system is designed to send campaigns to audience segments based on tags. That is *probably* not what you want, so you'll have to rip out that logic, which is easily done: just delete `"segment_opts" => segment_options` in `update_campaign_content`.

In general, I don't really expect this to be used as-is by anyone else, but it would have been a helpful starting point for me, six months ago, so now it can be a starting point for you!