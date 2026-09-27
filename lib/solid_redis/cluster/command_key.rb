# frozen_string_literal: true

module SolidRedis
  module Cluster
    # Extracts the routing key of a command. Most Redis commands carry their
    # first key as the second argument; the exceptions are listed here.
    module CommandKey
      KEYLESS = Ractor.make_shareable(
        %w[
          ACL ASKING AUTH BGREWRITEAOF BGSAVE CLIENT CLUSTER COMMAND CONFIG DBSIZE DEBUG DISCARD ECHO EXEC
          FAILOVER FLUSHALL FLUSHDB FUNCTION HELLO INFO LASTSAVE LATENCY LOLWUT MODULE MONITOR MULTI PING
          PSUBSCRIBE PUBLISH PUBSUB PUNSUBSCRIBE QUIT RANDOMKEY READONLY READWRITE REPLICAOF RESET ROLE SAVE
          SCAN SCRIPT SELECT SHUTDOWN SLAVEOF SLOWLOG SUBSCRIBE SWAPDB SYNC TIME UNSUBSCRIBE UNWATCH WAIT
        ].to_h { |name| [name, true] },
      )

      # Commands whose keys are announced by a "numkeys" argument.
      NUMKEYS_AT = Ractor.make_shareable({
        "EVAL" => 2, "EVALSHA" => 2, "EVAL_RO" => 2, "EVALSHA_RO" => 2,
        "FCALL" => 2, "FCALL_RO" => 2, "ZUNIONSTORE" => 2, "ZINTERSTORE" => 2, "ZDIFFSTORE" => 2,
        "ZUNION" => 1, "ZINTER" => 1, "ZDIFF" => 1, "SINTERCARD" => 1, "ZINTERCARD" => 1, "LMPOP" => 1, "ZMPOP" => 1,
        "BLMPOP" => 2, "BZMPOP" => 2,
      })

      STREAMS_COMMANDS = Ractor.make_shareable({ "XREAD" => true, "XREADGROUP" => true })

      module_function

      # Returns the first key of +command+, or nil for keyless commands.
      def for(command)
        name = command[0].to_s.upcase
        return if KEYLESS[name]

        if (index = NUMKEYS_AT[name])
          count = Integer(command[index], exception: false) || 0
          return count.positive? ? command[index + 1] : nil
        end

        if STREAMS_COMMANDS[name]
          streams = command.index { |argument| argument.to_s.casecmp?("STREAMS") }
          return streams && command[streams + 1]
        end

        case name
        when "MEMORY" then command[1].to_s.casecmp?("USAGE") ? command[2] : nil
        when "XGROUP", "XINFO", "OBJECT" then command[2]
        when "MIGRATE" then command[3].to_s.empty? ? nil : command[3]
        else command[1]
        end
      end
    end
  end
end
