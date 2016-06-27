FactoryGirl.define do
  test_process = Object.new
  test_process.extend(ActionDispatch::TestProcess)

  sequence :title do
    Faker::Lorem.words(3).join(' ')
  end

  factory :coupon do |m|
    m.title "My Special!"
    m.percent "25"
    m.association(:movie)
  end

  factory :quote do |m|
    m.text "Holy Cow!"
    m.quoted_at Time.now
    m.association(:movie)
  end

  factory :page_visit do |m|
    m.association :user
    m.association :movie
  end

  factory :clip do |m|
    m.name { Faker::Lorem.words(5).to_sentence }
    m.association(:movie)
  end

  factory :engagement_question do |e|
    e.ask {Faker::Lorem.words(5).to_sentence}
    e.association(:movie)
  end

  factory :event do |e|
    e.association(:studio)
  end

  factory :message do |m|
    m.content { Faker::Lorem.words(5).to_sentence }
    m.association(:event)
    m.association(:user)
  end

  factory :movie do |m|
    m.title { FactoryGirl.generate(:title) }
    m.price 30
    m.font_color_help '#387231'
    m.button_color_gradient_1 "#FFF"
    m.button_color_gradient_2 "#000"
    m.popup_bk_color_1 "#FFF"
    m.popup_bk_color_2 "#000"
    m.association(:studio)
    m.rental_length 100
    m.cdn_path "a_cdn/path"
    m.action_box_top '496'
    m.action_box_left '19'
    m.like_box_top 496
    m.like_box_left 250
    m.video_file_path "a_movie/path"
    m.feed_dialog_name "I'm watchin something!'"
    m.feed_dialog_link "http://apps.fb.com/blah"
    m.feed_dialog_caption "Something you'll like for sure!'"
    m.released true
    m.brightcove_movie_id '993114464001'
    m.age_restricted false
    m.after_create do |movie|
      movie.skin = FactoryGirl.create(:skin)
      movie.save
    end
  end

  factory :warner_movie, :parent => :movie do |m|
    m.association(:studio) { FactoryGirl.create(:warner_studio) }
    m.cdn_path "a_cdn/path"
    m.video_file_path "a_movie/path"
  end

  factory :studio do |s|
    s.name { Faker::Company.name }
    s.facebook_canvas_page "http://example.com/my_cool_app/"
    s.facebook_app_id "1234567890"
    s.facebook_app_secret "idontcare"
    s.help_text "If you need help, email sos@movie.net and wait 10 to 14 days."
    s.privacy_policy_url "http://wb.com/privacy"
    s.viewing_details { Faker::Lorem.sentence(5) }
    s.player 'movie'
    s.max_ips_for_movie 3
    s.genre_list "Comedy, Sci-Fi"
    s.group_buy_enabled false
  end

  factory :series do |s|
    s.association(:studio)
  end

  factory :bundle do |b|
    b.association(:series)
  end

  factory :warner_studio, :parent => :studio do |s|
    s.name "Warner Bros."
  end

  factory :brightcove_studio, :parent => :studio do |s|
    s.brightcove_id "993020440001"
    s.brightcove_key "AQ~~,FAKE~,KAZR-IVH77v-wHC6WxtQYB1D1Me4pgHX"
  end

  factory :order, :class => Stripe do |o|
    o.association(:movie)
    o.association(:user)
    o.unit_price 0
    o.transaction_uid "S1234"
  end

  factory :paypal, :parent => :order do |p|
  end

  factory :fb_credit do |o|
    total_credits '30'
    facebook_order_id 'FB1234'
    o.association(:movie)
    o.association(:user)
  end

  factory :group_discount do |o|
    o.association(:order)
    o.discount_key KeyGenerator.generate
  end

  factory :admin do |admin|
    admin.email { Faker::Internet.email }
    admin.password { "#{Faker::Internet.user_name}password" }
    admin.configuration_only true
    admin.reporting_only true
  end

  factory :studio_admin, :parent => :admin do |admin|
    admin.association :studio
  end


  factory :moderator, :parent => :admin do |moderator|
    moderator.password "password"
  end

  factory :studio_moderator, :parent => :moderator do |moderator|
    moderator.association :studio
  end

  factory :settled_order, :parent => :order do |o|
    o.status "settled"
    o.rented_at { Time.now }
  end

  factory :invitation do |invite|
    invite.email { Faker::Internet.email }
  end
  factory :skin do |skin|
    Skin.attachment_definitions.keys.each do |attachment|
      skin.send(attachment, test_process.fixture_file_upload(Rails.root.join('spec/support/images/image.jpg'), 'image/png'))
    end
  end

  factory :user do |fb_user|
    fb_user.name { Faker::Name.name + rand(999999).to_s }
    fb_user.facebook_user_id {rand(999999).to_s}
    fb_user.access_token "TOKEN"
    #fb_user.gender "Male"
    #fb_user.email { Faker::Internet.email(fb_user.name) }
    #fb_user.birthday =
    #fb_user.country = fb_graph.data[:user][:country].try(:upcase)
    #fb_user.city, self.state = fb_user.location.name.to_s.split(",").map(&:strip) if fb_user.location
  end

  factory :watch_visit, :class => PageVisit do |visit|
    visit.association :movie
    visit.association :user
    visit.page 'watch'
  end

  factory :purchase_visit, :class => PageVisit do |visit|
    visit.association :movie
    visit.association :user
    visit.page 'purchase'
  end

  factory :poll, :class => EngagementQuestion do |o|
    o.association :movie
    o.ask "what is your favorite moment?"
    o.kind "poll"
    o.answer_1 "blue"
    o.answer_2 "red"
  end


end
