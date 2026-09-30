# frozen_string_literal: true

module SolidRedis
  module Cluster
    # Maps a Redis key to one of the 16384 cluster hash slots using CRC16
    # (XMODEM) and the +{hash tag}+ rule from the Redis Cluster specification.
    module KeySlot
      SLOTS = 16_384

      # CRC16 XMODEM lookup table (polynomial 0x1021).
      TABLE = Ractor.make_shareable(
        Array.new(256) do |byte|
          crc = byte << 8
          8.times { crc = (crc & 0x8000).zero? ? (crc << 1) & 0xFFFF : ((crc << 1) ^ 0x1021) & 0xFFFF }
          crc
        end,
      )

      module_function

      def for(key)
        string = key.to_s
        first = 0
        last = string.bytesize
        if (open = string.index("{")) &&
            (close = string.index("}", open + 1)) &&
            close > open + 1
          first = open + 1
          last = close
        end

        crc16_range(string, first, last) % SLOTS
      end

      def hash_tag(key)
        open = key.index("{")
        return key unless open

        close = key.index("}", open + 1)
        return key unless close && close > open + 1

        key[(open + 1)...close]
      end

      def crc16(string)
        crc16_range(string, 0, string.bytesize)
      end

      def crc16_range(string, first, last)
        crc = 0
        while first < last
          byte = string.getbyte(first)
          crc = ((crc << 8) & 0xFFFF) ^ TABLE[((crc >> 8) ^ byte) & 0xFF]
          first += 1
        end
        crc
      end
    end
  end
end
