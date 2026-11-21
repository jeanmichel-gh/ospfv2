require 'test/unit'
require 'open3'
require 'tmpdir'

# test/lab/bases.sh: the base images a lab build needs, tagged before the
# build, so BuildKit does not ask Docker Hub for them (bases.sh's header).
class TestLabBases < Test::Unit::TestCase
  ROOT = File.expand_path('../../..', __dir__)
  BASES = File.join(ROOT, 'test/lab/bases.sh')

  def list(*files)
    out, status = Open3.capture2(BASES, '--list', *files)
    assert status.success?
    out.split
  end

  def test_args_stages_and_scratch
    Dir.mktmpdir do |dir|
      f = File.join(dir, 'Dockerfile')
      File.write(f, <<~DOCKERFILE)
        ARG RUBY_VERSION=3.4
        ARG GOBGP_IMAGE=jauderho/gobgp:v4.10.0
        FROM --platform=$BUILDPLATFORM node:22-slim AS web
        FROM ruby:${RUBY_VERSION}-slim AS base
        FROM base AS speaker
        from Speaker as lab-node
        FROM ${GOBGP_IMAGE} AS gobgp-cli
        FROM scratch
        FROM ruby:$RUBY_VERSION-slim
      DOCKERFILE
      assert_equal %w[node:22-slim ruby:3.4-slim jauderho/gobgp:v4.10.0], list(f)
    end
  end

  # Not in the test image, which has test/ but not the Dockerfiles.
  def test_our_dockerfiles
    files = [File.join(ROOT, 'Dockerfile'), File.join(ROOT, 'docker/bird/Dockerfile')]
    omit('the Dockerfiles are not here') unless files.all? { File.file?(_1) }
    images = list(*files)
    assert_equal 2, images.size, images.inspect
    assert_match(/\Aruby:[\d.]+-slim\z/, images[0])
    assert_equal 'debian:bookworm-slim', images[1]
  end

  # Every image build in a lab script tags its bases first, unless
  # SKIP_BUILD skips both.
  def test_every_lab_build_tags_its_bases_first
    Dir[File.join(ROOT, 'test/lab/*.sh')].each do |script|
      lines = File.readlines(script)
      lines.each_with_index do |line, i|
        next unless line.match?(/docker build /) && !line.lstrip.start_with?('#')

        before = lines[0...i].reverse.find { _1.include?('test/lab/bases.sh') }
        assert before, "#{File.basename(script)}:#{i + 1} builds without test/lab/bases.sh before it"
      end
    end
  end
end
