class MCollective::Application::Shell < MCollective::Application
  description 'Run shell commands innit'

  usage <<-END_OF_USAGE
mco shell [OPTIONS] [FILTERS] <ACTION> [ARGS]

  mco shell start [COMMAND]
  mco shell watch [HANDLE]
  mco shell tail [COMMAND]
END_OF_USAGE

  def post_option_parser(configuration)
    configuration[:command] = ARGV.shift
  end

  def main
    send("#{configuration[:command]}_command")
  end

  private

  class Watcher
    attr_reader :node, :handle
    attr_reader :stdout_offset, :stderr_offset

    def initialize(node, handle)
      @node = node
      @handle = handle
      @stdout = PrefixStreamBuf.new("#{node} stdout: ")
      @stderr = PrefixStreamBuf.new("#{node} stderr: ")
      @stdout_offset = 0
      @stderr_offset = 0
    end

    def status(response)
      @stdout_offset += response[:data][:stdout].size
      @stdout.display(response[:data][:stdout])
      @stderr_offset += response[:data][:stderr].size
      @stderr.display(response[:data][:stderr])
    end

    def flush
      @stdout.flush
      @stderr.flush
    end

    private

    class PrefixStreamBuf
      def initialize(prefix)
        @buffer = ''
        @prefix = prefix
      end

      def display(data)
        @buffer += data
        chunks = @buffer.lines.to_a
        return if chunks.empty?

        if chunks[-1][-1] != "\n"
          @buffer = chunks[-1]
          chunks.pop
        else
          @buffer = ''
        end

        chunks.each do |chunk|
          puts "#{@prefix}#{chunk}"
        end
      end

      def flush
        if @buffer.size > 0
          display("\n")
        end
      end
    end
  end

  def start_command
    command = ARGV.join(' ')
    client = rpcclient('shell')

    responses = client.start(:command => command)

    responses.sort { |a,b| a[:sender] <=> b[:sender] }.each do |response|
      if response[:statuscode] == 0
        puts "#{response[:sender]}: #{response[:data][:handle]}"
      else
        puts "#{response[:sender]}: ERROR: #{response.inspect}"
      end
    end
    printrpcstats :summarize => true, :caption => "Started command: #{command}"
  end

  def watch_command
    handles = ARGV
    client = rpcclient('shell')

    watchers = []
    client.list.each do |response|
      next if response[:statuscode] != 0
      puts response.inspect
      response[:data][:jobs].keys.each do |handle|
        if handles.include?(handle)
          watchers << Watcher.new(response[:sender], handle)
        end
      end
    end

    watch_these(client, watchers)
  end

  def tail_command
    command = ARGV.join(' ')
    client = rpcclient('shell')

    processes = []
    client.start(:command => command).each do |response|
      next unless response[:statuscode] == 0
      processes << Watcher.new(response[:sender], response[:data][:handle])
    end

    watch_these(client, processes, true)
  end

  def watch_these(client, processes, kill_on_interrupt = false)
    client.progress = false

    state = :running
    if kill_on_interrupt
      # trap sigint so we can send a kill to the commands we're watching
      trap('SIGINT') do
        puts "Attempting to stopping cleanly, interrupt again to kill"
        state = :stopping

        # if we're double-tapped, just quit (may leave a mess)
        trap('SIGINT') do
          puts "OK you meant it; bye"
          exit 1
        end
      end
    else
      # When we get a sigint we should just exit
      trap('SIGINT') do
        puts ""
        exit 1
      end
    end

    while !processes.empty?
      processes.each do |process|
        #puts process.inspect
        client.filter["identity"].clear
        client.identity_filter process.node

        if state == :stopping && kill_on_interrupt
          puts "Sending kill to #{process.node} #{process.handle}"
          client.kill(:handle => process.handle)
        end

        client.status({
          :handle => process.handle,
          :stdout_offset => process.stdout_offset,
          :stderr_offset => process.stderr_offset,
        }).each do |response|
          #puts response.inspect

          if response[:statuscode] != 0
            process.flush
            processes.delete(process)
            break
          end

          process.status(response)

          if response[:data][:status] == :stopped
            process.flush
            processes.delete(process)
          end
        end
      end
    end
  end
end