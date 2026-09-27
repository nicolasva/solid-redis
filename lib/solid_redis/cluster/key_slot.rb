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
        crc16(hash_tag(key.to_s)) % SLOTS
      end

      def hash_tag(key)
        open = key.index("{")
        return key unless open

        close = key.index("}", open + 1)
        return key unless close && close > open + 1

        key[(open + 1)...close]
      end

      def crc16(string)
        string.each_byte.reduce(0) do |crc, byte|
          ((crc << 8) & 0xFFFF) ^ TABLE[((crc >> 8) ^ byte) & 0xFF]
        end
      end
    end
  end
end
