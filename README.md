# heroku-aspen-migrate

Attempt (mostly) automatic upgrade of an app from Aspen to Cedar. This script will attempt to create a new app named `myapp-cedar` that mimics the original as closely as possible.

## Installation

    $ heroku plugins:install https://github.com/ddollar/heroku-aspen-migrate

## Usage

Heroku's Aspen migration will create a Ruby 1.8.7 Cedar app. Due to limitations of Bundler, you will need to run the migration script from Ruby 1.8.7.

    $ heroku maintenance:on -a myapp
    $ heroku aspen:migrate -a myapp

This will cause an app named `myapp-cedar` to be created, and the following operations performed:

* If the app is using a Heroku Postgres database as `DATABASE_URL`, the same type of database will be added to the new app.
* Installation of the `pgbackups` addon to the Aspen app if it is not already installed.
* All addons installed on the Aspen app will be installed on the Cedar app
* Pgbackups will be used to transfer the Aspen app's data to the Cedar app
* The Aspen app's config (minus Aspen-specific vars) will be copied to the Cedar app
* A Gemfile will be written that merges the gems in a `.gems` manifest if it exists
* `bundle install` will be run locally to resolve the new Gemfile
* The app will be pushed to its new Cedar home

## After the migration

Verify the new app at https://myapp-cedar.herokuapp.com

If you need to make any changes, clone the new app:

    $ git clone myapp-cedar -o heroku

If everything looks good, remove all domains from the Aspen app and add them to the Cedar app. You may also want to rename `myapp` to `myapp-aspen` and `myapp-cedar` to `myapp` if you are taking advantage of the `*.heroku.com` or `*.herokuapp.com` domains.
