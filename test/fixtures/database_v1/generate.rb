# frozen_string_literal: true
# encoding: utf-8

require "multi_compress"
require "multi_compress/database"

D = MultiCompress::Database
DIR = __dir__

def write(name, bytes)
  File.binwrite(File.join(DIR, name), bytes)
end

def envelope_for(raw_bytes)
  frame = MultiCompress.compress(raw_bytes, algo: :zstd, level: D::ZSTD_LEVEL)
  D::MAGIC +
    [D::VERSION, D::CODEC_ZSTD, D::FLAGS_V1].pack("C3") +
    [raw_bytes.bytesize].pack("Q<") +
    [MultiCompress.crc32(raw_bytes)].pack("L<") +
    frame
end

{
  "utf8_text"  => "Привет, мир! Сәлем әлем! 🌍",
  "empty_text" => "",
  "large_text" => (("lorem ipsum dolor sit amet " * 4999) + "lorem ipsum dolor sit amet"),
}.each do |name, text|
  write("#{name}.mcdb", D.compress(text))
  write("#{name}.expected", text.dup.force_encoding(Encoding::BINARY))
end

good = D.compress("some payload text")
write("corrupt_magic.mcdb",   good.dup.tap { |x| x.setbyte(0, 0x00) })
write("wrong_version.mcdb",   good.dup.tap { |x| x.setbyte(4, 0x02) })
write("corrupt_payload.mcdb", good.dup.tap { |x| x.setbyte(x.bytesize - 1, x.getbyte(x.bytesize - 1) ^ 0xFF) })
write("corrupt_crc.mcdb",     good.dup.tap { |x| x.setbyte(15, x.getbyte(15) ^ 0xFF) })
write("invalid_utf8.mcdb", envelope_for("\xFF\xFEvalid-looking".b))
write("nul_text.mcdb", envelope_for("valid\x00looking".b))

first = D.compress("single frame only")
first_frame = first.byteslice(D::HEADER_SIZE, first.bytesize - D::HEADER_SIZE)
skippable = [0x184D2A50, 0].pack("L<L<")
write("trailing_skippable.mcdb", first + skippable)
write("trailing_frame.mcdb", first + MultiCompress.compress("second frame", algo: :zstd, level: D::ZSTD_LEVEL))

if $PROGRAM_NAME == __FILE__
  puts "wrote fixtures to #{DIR}:"
  Dir[File.join(DIR, "*")].sort.each { |f| puts "  #{File.basename(f)} (#{File.size(f)}b)" }
end
