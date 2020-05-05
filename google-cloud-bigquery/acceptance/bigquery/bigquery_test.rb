# Copyright 2015 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "bigquery_helper"

describe Google::Cloud::Bigquery, :bigquery do
  let(:publicdata_query) { "SELECT url FROM `bigquery-public-data.samples.github_nested` LIMIT 100" }
  let(:dataset_id) { "#{prefix}_dataset" }
  let(:dataset) do
    d = bigquery.dataset dataset_id
    if d.nil?
      d = bigquery.create_dataset dataset_id
    end
    d
  end
  let(:labels) { { "prefix" => prefix } }
  let(:udfs) { [ "return x+1;", "gs://my-bucket/my-lib.js" ] }
  let(:filter) { "labels.prefix:#{prefix}" }
  let(:dataset_2_id) { "#{prefix}_dataset_2" }
  let(:dataset_2) do
    d = bigquery.dataset dataset_2_id
    if d.nil?
      d = bigquery.create_dataset dataset_2_id do |ds|
        ds.labels = labels
      end
    end
    d
  end
  let(:table_id) { "bigquery_table" }
  let(:table) do
    t = dataset.table table_id
    if t.nil?
      t = dataset.create_table table_id
    end
    t
  end
  let(:view_id) { "bigquery_view" }
  let(:view) do
    t = dataset.table view_id
    if t.nil?
      t = dataset.create_view view_id, publicdata_query
    end
    t
  end
  let(:dataset_with_access_id) { "#{prefix}_dataset_with_access" }

  before do
    dataset_2
    table
    view
  end

  it "should get its project service account email" do
    email = bigquery.service_account_email
    _(email).wont_be :nil?
    _(email).must_be_kind_of String
    # https://stackoverflow.com/questions/22993545/ruby-email-validation-with-regex
    _(email).must_match /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
  end

  it "should get a list of datasets" do
    datasets = bigquery.datasets max: 1
    # The code in before ensures we have at least one dataset
    _(datasets.count).wont_be :zero?
    datasets.all(request_limit: 1).each do |ds|
      _(ds).must_be_kind_of Google::Cloud::Bigquery::Dataset
      _(ds.created_at).must_be_kind_of Time # Loads full representation
    end
    more_datasets = datasets.next
    _(more_datasets).wont_be :nil?
  end

  it "should get a list of datasets by labels filter" do
    datasets = bigquery.datasets filter: filter
    _(datasets.count).must_equal 1
    ds = datasets.first
    _(ds).must_be_kind_of Google::Cloud::Bigquery::Dataset
    _(ds.labels).must_equal labels
  end

  it "create a dataset with access rules" do
    bigquery.create_dataset dataset_with_access_id do |ds|
      ds.access do |acl|
        acl.add_writer_special :all
      end
    end
    fresh = bigquery.dataset dataset_with_access_id
    _(fresh).wont_be :nil?
    _(fresh.access).wont_be :empty?
    _(fresh.access.to_a).must_be_kind_of Array
    assert fresh.access.writer_special? :all
  end

  it "should run a query" do
    rows = bigquery.query publicdata_query
    _(rows.class).must_equal Google::Cloud::Bigquery::Data
    _(rows.count).must_equal 100
  end

  it "should run a query without legacy SQL syntax" do
    rows = bigquery.query publicdata_query, legacy_sql: false
    _(rows.class).must_equal Google::Cloud::Bigquery::Data
    _(rows.count).must_equal 100
  end

  it "should run a query with standard SQL syntax" do
    rows = bigquery.query publicdata_query, standard_sql: true
    _(rows.class).must_equal Google::Cloud::Bigquery::Data
    _(rows.count).must_equal 100
  end

  it "should run a query job with job id" do
    job_id = "test_job_#{SecureRandom.urlsafe_base64(21)}" # client-generated
    job = bigquery.query_job publicdata_query, job_id: job_id
    _(job).must_be_kind_of Google::Cloud::Bigquery::Job
    _(job.job_id).must_equal job_id
    _(job.user_email).wont_be_nil

    _(job.range_partitioning?).must_equal false
    _(job.range_partitioning_field).must_be_nil
    _(job.range_partitioning_start).must_be_nil
    _(job.range_partitioning_interval).must_be_nil
    _(job.range_partitioning_end).must_be_nil
    _(job.time_partitioning?).must_equal false
    _(job.time_partitioning_type).must_be :nil?
    _(job.time_partitioning_field).must_be :nil?
    _(job.time_partitioning_expiration).must_be :nil?
    _(job.time_partitioning_require_filter?).must_equal false
    _(job.clustering?).must_equal false
    _(job.clustering_fields).must_be :nil?

    job.wait_until_done!
    rows = job.data
    _(rows.total).must_equal 100

    # @gapi.statistics.query
    _(job.bytes_processed).must_equal 0
    _(job.query_plan).must_be :nil?
    # Sometimes values are nil in the returned job, so currently comment out unreliable expectations
    # job.statement_type.must_equal "SELECT"
    _(job.ddl_operation_performed).must_be :nil?
    _(job.ddl_target_table).must_be :nil?
    _(job.ddl_target_routine).must_be :nil?
  end

  it "should run a query job with dryrun flag" do
    job = bigquery.query_job publicdata_query, dryrun: true
    _(job.dryrun?).must_equal true
    _(job.dryrun).must_equal true # alias
    _(job.dry_run).must_equal true # alias
    _(job.dry_run?).must_equal true # alias

    job.wait_until_done!
    data = job.data
    _(data.count).must_equal 0
    _(data.next?).must_equal false
    _(data.total).must_be :nil?
    _(data.schema).must_be :nil?
    _(data.statement_type).must_equal "SELECT"

    # @gapi.statistics.query
    _(job.bytes_processed).must_be :>, 0 # 155625782
    _(job.query_plan).must_be :nil?
  end

  it "should run a query job with job labels" do
    job = bigquery.query_job publicdata_query, labels: labels
    _(job).must_be_kind_of Google::Cloud::Bigquery::Job
    _(job.labels).must_equal labels
  end

  it "should run a query job with user defined function resources" do
    job = bigquery.query_job publicdata_query, udfs: udfs
    _(job).must_be_kind_of Google::Cloud::Bigquery::Job
    _(job.udfs).must_equal udfs
  end

  it "should run a query job with job labels and user defined function resources in a block updater" do
    job = bigquery.query_job publicdata_query do |j|
      j.labels = labels
      j.udfs = udfs
    end
    _(job).must_be_kind_of Google::Cloud::Bigquery::Job
    _(job.labels).must_equal labels
    _(job.udfs).must_equal udfs
  end

  it "should get a list of jobs" do
    jobs = bigquery.jobs.all request_limit: 3
    jobs.each { |job| _(job).must_be_kind_of Google::Cloud::Bigquery::Job }
  end

  it "should get a list of projects" do
    projects = bigquery.projects.all
    _(projects.count).must_be :>, 0
    projects.each do |project|
      _(project).must_be_kind_of Google::Cloud::Bigquery::Project
      _(project.name).must_be_kind_of String
      _(project.service).must_be_kind_of Google::Cloud::Bigquery::Service
      _(project.service.project).must_be_kind_of String
      project.datasets.each do |ds|
        _(ds).must_be_kind_of Google::Cloud::Bigquery::Dataset
      end
    end
  end

  it "extracts a readonly table to a GCS url with extract" do
    Tempfile.open "empty_extract_file.csv" do |tmp|
      dest_file_name = random_file_destination_name
      extract_url = "gs://#{bucket.name}/#{dest_file_name}"
      result = bigquery.extract samples_public_table, extract_url do |j|
        j.location = "US"
      end
      _(result).must_equal true

      extract_file = bucket.file dest_file_name
      downloaded_file = extract_file.download tmp.path
      _(downloaded_file.size).must_be :>, 0
    end
  end

  it "copies a readonly table to another table with copy" do
    result = bigquery.copy samples_public_table, "#{dataset_id}.shakespeare_copy", create: :needed, write: :empty do |j|
      j.location = "US"
    end
    _(result).must_equal true
  end
end