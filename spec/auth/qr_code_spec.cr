# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Lecteur QR code minimal, écrit d'après la norme (ISO/IEC 18004) et
# indépendant de l'encodeur : zones fonctionnelles, informations de format,
# lecture en zigzag, désentrelacement, syndromes Reed-Solomon, segment octet.
module QrReader
  EXP = begin
    table = Array.new(512, 0)
    x = 1
    255.times do |i|
      table[i] = x
      x <<= 1
      x ^= 0x11D if x & 0x100 != 0
    end
    (255...512).each { |i| table[i] = table[i - 255] }
    table
  end

  def self.gf_mul(a : Int32, b : Int32, log : Array(Int32)) : Int32
    return 0 if a == 0 || b == 0
    EXP[log[a] + log[b]]
  end

  LOG = begin
    table = Array.new(256, 0)
    255.times { |i| table[EXP[i]] = i }
    table
  end

  def self.function?(version : Int32, x : Int32, y : Int32) : Bool
    size = version * 4 + 17
    x == 6 || y == 6 || corner?(size, x, y) || version_area?(version, size, x, y) || alignment?(version, size, x, y)
  end

  # Motifs de repérage, séparateurs et informations de format.
  def self.corner?(size : Int32, x : Int32, y : Int32) : Bool
    (x < 9 && y < 9) || (x >= size - 8 && y < 9) || (x < 9 && y >= size - 8)
  end

  def self.version_area?(version : Int32, size : Int32, x : Int32, y : Int32) : Bool
    return false if version < 7
    (x < 6 && size - 11 <= y < size - 8) || (y < 6 && size - 11 <= x < size - 8)
  end

  def self.alignment?(version : Int32, size : Int32, x : Int32, y : Int32) : Bool
    centers = Partiduo::Auth::QrCode.alignment_positions(version)
    centers.any? do |center_x|
      centers.any? do |center_y|
        next false if {center_x, center_y}.in?({6, 6}, {6, size - 7}, {size - 7, 6})
        (x - center_x).abs <= 2 && (y - center_y).abs <= 2
      end
    end
  end

  # Masque lu dans la première copie des informations de format.
  def self.read_format(qr : Partiduo::Auth::QrCode) : Int32
    bits = 0
    positions = (0..5).map { |i| {8, i} } + [{8, 7}, {8, 8}, {7, 8}] + (9..14).map { |i| {14 - i, 8} }
    positions.each_with_index { |(x, y), i| bits |= 1 << i if qr.dark?(x, y) }
    raw = bits ^ 0x5412
    data = raw >> 10
    # Vérification BCH : le reste recalculé doit correspondre.
    remainder = data
    10.times { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
    raise "format BCH invalide" unless (data << 10 | remainder) == raw
    raise "niveau de correction #{data >> 3}, M attendu" unless data >> 3 == 0
    data & 7
  end

  def self.codewords(qr : Partiduo::Auth::QrCode, mask : Int32) : Array(Int32)
    size = qr.size
    bits = [] of Bool
    column = size - 1
    upward = true
    while column > 0
      column -= 1 if column == 6
      rows = upward ? (size - 1).downto(0).to_a : (0...size).to_a
      rows.each do |y|
        [column, column - 1].each do |x|
          next if function?(qr.version, x, y)
          bits << (qr.dark?(x, y) ^ Partiduo::Auth::QrCode.mask_bit?(mask, x, y))
        end
      end
      upward = !upward
      column -= 2
    end
    bits.each_slice(8).select { |byte| byte.size == 8 }.map { |byte| byte.reduce(0) { |acc, bit| acc << 1 | (bit ? 1 : 0) } }.to_a
  end

  # Désentrelace les blocs et vérifie leurs syndromes ; renvoie les données.
  def self.data(qr : Partiduo::Auth::QrCode, codewords : Array(Int32)) : Array(Int32)
    version = qr.version
    blocks_count = Partiduo::Auth::QrCode::BLOCKS[version]
    ecc = Partiduo::Auth::QrCode::ECC_PER_BLOCK[version]
    total = Partiduo::Auth::QrCode.raw_data_modules(version) // 8
    codewords = codewords[0, total]
    short = total // blocks_count
    short_count = blocks_count - total % blocks_count
    lengths = Array.new(blocks_count) { |i| short - ecc + (i < short_count ? 0 : 1) }
    blocks = Array.new(blocks_count) { [] of Int32 }
    index = 0
    lengths.max.times do |i|
      blocks_count.times do |b|
        next if i >= lengths[b]
        blocks[b] << codewords[index]
        index += 1
      end
    end
    ecc.times do |_|
      blocks_count.times do |b|
        blocks[b] << codewords[index]
        index += 1
      end
    end
    blocks.each do |block|
      ecc.times do |power|
        syndrome = 0
        block.each { |coefficient| syndrome = gf_mul(syndrome, EXP[power], LOG) ^ coefficient }
        raise "syndrome non nul : bloc corrompu" unless syndrome == 0
      end
    end
    blocks.each_with_index.flat_map { |block, b| block[0, lengths[b]] }.to_a
  end

  def self.decode(qr : Partiduo::Auth::QrCode) : String
    mask = read_format(qr)
    bytes = data(qr, codewords(qr, mask))
    bits = bytes.flat_map { |byte| (0..7).map { |i| (byte >> (7 - i)) & 1 } }
    read = ->(count : Int32) { value = bits[0, count].reduce(0) { |acc, bit| acc << 1 | bit }; bits = bits[count..]; value }
    raise "mode #{bits[0, 4]}" unless read.call(4) == 0b0100
    length = read.call(qr.version < 10 ? 8 : 16)
    String.new(Bytes.new(length) { read.call(8).to_u8 })
  end
end

describe Partiduo::Auth::QrCode do
  it "place les motifs de repérage et le module sombre fixe" do
    qr = Partiduo::Auth::QrCode.encode("HELLO")
    qr.version.should eq(1)
    qr.size.should eq(21)
    qr.to_s.lines.first.should start_with("#######.")
    qr.dark?(8, qr.size - 8).should be_true
  end

  it "calcule les positions des motifs d'alignement de la norme" do
    Partiduo::Auth::QrCode.alignment_positions(2).should eq([6, 18])
    Partiduo::Auth::QrCode.alignment_positions(7).should eq([6, 22, 38])
    Partiduo::Auth::QrCode.alignment_positions(14).should eq([6, 26, 46, 66])
  end

  it "donne les capacités octet de la norme en correction M" do
    {1 => 14, 2 => 26, 5 => 84, 7 => 122, 10 => 213, 15 => 412}.each do |version, capacity|
      overhead = version < 10 ? 2 : 3
      (Partiduo::Auth::QrCode.data_codewords(version) - overhead).should eq(capacity)
    end
  end

  it "code les informations de version (BCH 18,6)" do
    Partiduo::Auth::QrCode.version_bits(7).should eq(0x07C94)
    Partiduo::Auth::QrCode.version_bits(15).should eq(0x0F928)
  end

  it "se relit : format, syndromes Reed-Solomon et données, versions 1 à 15" do
    [1, 13, 26, 60, 84, 106, 122, 152, 180, 213, 251, 287, 331, 362, 412].each do |length|
      text = String.build { |io| length.times { |i| io << ('a' + i % 26) } }
      qr = Partiduo::Auth::QrCode.encode(text)
      QrReader.read_format(qr).should eq(qr.mask)
      QrReader.decode(qr).should eq(text)
    end
  end

  it "porte une URI otpauth:// d'enrôlement TOTP" do
    uri = "otpauth://totp/Partiduo:claire.expert%40cabinet-comptable.example?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=Partiduo&algorithm=SHA1&digits=6&period=30"
    QrReader.decode(Partiduo::Auth::QrCode.encode(uri)).should eq(uri)
  end

  it "refuse un contenu trop long" do
    expect_raises(Partiduo::Auth::QrCode::TooLong) { Partiduo::Auth::QrCode.encode("x" * 413) }
  end
end
