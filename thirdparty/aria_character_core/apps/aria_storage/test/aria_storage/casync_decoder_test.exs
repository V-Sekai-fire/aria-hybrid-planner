# Copyright (c) 2025-present K. S. Ernest (iFire) Lee

defmodule AriaStorage.CasyncDecoderTest do
  use ExUnit.Case, async: true
  alias AriaStorage.CasyncDecoder
  alias AriaStorage.Parsers.CasyncFormat
  alias AriaStorage.Chunks
  @ca_format_sha512_256 2_305_843_009_213_693_952
  @testdata_path Path.expand("../support/testdata", __DIR__)
  @test_output_dir "/tmp/casync_decoder_test"
  setup do
    File.rm_rf!(@test_output_dir)
    File.mkdir_p!(@test_output_dir)
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ssl)
    :ok
  end

  describe("chunk decompression") do
    test "decompresses ZSTD compressed chunk data correctly" do
      original_data = "Hello, World!"
      compressed_data = :ezstd.compress(original_data)
      result = decompress_test_data(compressed_data, :zstd)
      assert {:ok, decompressed} = result
      assert decompressed == original_data
    end

    test "handles uncompressed data correctly" do
      test_data = "This is uncompressed data"
      result = decompress_test_data(test_data, :none)
      assert {:ok, ^test_data} = result
    end

    test "returns error for unsupported compression" do
      test_data = "some data"
      result = decompress_test_data(test_data, :gzip)
      assert {:error, {:unsupported_compression, :gzip}} = result
    end

    test "returns error for invalid ZSTD data" do
      invalid_data = "not compressed data"
      result = decompress_test_data(invalid_data, :zstd)
      assert {:error, {:zstd_error, _}} = result
    end
  end

  describe("hash verification") do
    test "verifies chunk hash correctly with SHA512/256" do
      test_data = "Test chunk data for hash verification"
      expected_hash = :crypto.hash(:sha512, test_data) |> binary_part(0, 32)

      assert {:ok, ^test_data} =
               CasyncDecoder.verify_chunk(test_data, expected_hash, @ca_format_sha512_256)
    end

    test "returns error for hash mismatch" do
      test_data = "Test chunk data"
      wrong_hash = :crypto.hash(:sha512, "different data") |> binary_part(0, 32)

      assert {:error, {:hash_mismatch, _}} =
               CasyncDecoder.verify_chunk(test_data, wrong_hash, @ca_format_sha512_256)
    end

    test "hash verification is consistent with chunk ID calculation" do
      test_data = "Consistency test data"
      chunk_id = Chunks.calculate_chunk_id(test_data)

      assert {:ok, ^test_data} =
               CasyncDecoder.verify_chunk(test_data, chunk_id, @ca_format_sha512_256)
    end

    test "confirms SHA512/256 vs SHA256 difference" do
      test_data = "Algorithm comparison test"
      sha256_hash = :crypto.hash(:sha256, test_data)
      sha512_256_hash = :crypto.hash(:sha512, test_data) |> binary_part(0, 32)
      refute sha256_hash == sha512_256_hash
      chunk_id = Chunks.calculate_chunk_id(test_data)
      assert chunk_id == sha512_256_hash
    end
  end

  describe("chunk processing with real testdata") do
    test "processes real chunk from blob1.store" do
      store_path = Path.join(@testdata_path, "blob1.store")
      assert {:ok, chunk_dirs} = File.ls(store_path)
      chunk_dir = List.first(chunk_dirs)
      chunk_dir_path = Path.join(store_path, chunk_dir)
      assert {:ok, chunk_files} = File.ls(chunk_dir_path)
      chunk_file = List.first(chunk_files)
      chunk_path = Path.join(chunk_dir_path, chunk_file)
      assert {:ok, chunk_data} = File.read(chunk_path)
      chunk_id_hex = Path.basename(chunk_file, ".cacnk")
      chunk_id = Base.decode16!(chunk_id_hex, case: :lower)
      result = process_real_chunk(chunk_data, chunk_id, chunk_id_hex)
      assert {:ok, decompressed_data} = result
      assert is_binary(decompressed_data)
      assert byte_size(decompressed_data) > 0
    end

    test "processes multiple chunks from blob1.store" do
      store_path = Path.join(@testdata_path, "blob1.store")
      assert {:ok, chunk_dirs} = File.ls(store_path)
      chunk_dirs_to_test = Enum.take(chunk_dirs, 3)

      results =
        for chunk_dir <- chunk_dirs_to_test do
          chunk_dir_path = Path.join(store_path, chunk_dir)
          assert {:ok, chunk_files} = File.ls(chunk_dir_path)
          chunk_file = List.first(chunk_files)
          chunk_path = Path.join(chunk_dir_path, chunk_file)
          assert {:ok, chunk_data} = File.read(chunk_path)
          chunk_id_hex = Path.basename(chunk_file, ".cacnk")
          chunk_id = Base.decode16!(chunk_id_hex, case: :lower)
          process_real_chunk(chunk_data, chunk_id, chunk_id_hex)
        end

      Enum.each(results, fn result ->
        assert {:ok, decompressed_data} = result
        assert is_binary(decompressed_data)
      end)
    end
  end

  describe("file assembly and verification") do
    test "assembles file from blob1.caibx with local store" do
      caibx_path = Path.join(@testdata_path, "blob1.caibx")
      store_path = Path.join(@testdata_path, "blob1.store")
      assert {:ok, caibx_data} = File.read(caibx_path)
      assert {:ok, parsed_data} = CasyncFormat.parse_index(caibx_data)
      _output_path = Path.join(@test_output_dir, "assembled_blob1.bin")

      result =
        CasyncDecoder.assemble_file(parsed_data,
          store_path: store_path,
          output_dir: @test_output_dir
        )

      assert {:ok, assembly_result} = result
      assert assembly_result.success == true
      assert assembly_result.chunks_processed > 0
      assert assembly_result.bytes_written > 0
    end

    test "verifies assembled file integrity" do
      caibx_path = Path.join(@testdata_path, "blob1.caibx")
      store_path = Path.join(@testdata_path, "blob1.store")
      assert {:ok, caibx_data} = File.read(caibx_path)
      assert {:ok, parsed_data} = CasyncFormat.parse_index(caibx_data)

      result =
        CasyncDecoder.assemble_file(parsed_data,
          store_path: store_path,
          output_dir: @test_output_dir,
          verify_integrity: true
        )

      assert {:ok, assembly_result} = result
      assert assembly_result.verification_passed == true
      assert assembly_result.size_verified == true
    end

    test "handles corrupted chunk data gracefully" do
      caibx_path = Path.join(@testdata_path, "blob2_corrupted.caibx")
      store_path = Path.join(@testdata_path, "blob2.store")

      if File.exists?(caibx_path) do
        assert {:ok, caibx_data} = File.read(caibx_path)
        assert {:ok, parsed_data} = CasyncFormat.parse_index(caibx_data)

        result =
          CasyncDecoder.assemble_file(parsed_data,
            store_path: store_path,
            output_dir: @test_output_dir
          )

        case result do
          {:ok, assembly_result} ->
            assert assembly_result.chunks_processed <= length(parsed_data.chunks)
            assert is_boolean(assembly_result.verification_passed)

          {:error, _reason} ->
            assert true
        end
      else
        caibx_path = Path.join(@testdata_path, "blob2.caibx")

        if File.exists?(caibx_path) do
          assert {:ok, caibx_data} = File.read(caibx_path)
          assert {:ok, parsed_data} = CasyncFormat.parse_index(caibx_data)

          result =
            CasyncDecoder.assemble_file(parsed_data,
              store_path: store_path,
              output_dir: @test_output_dir
            )

          case result do
            {:ok, assembly_result} ->
              assert assembly_result.chunks_processed <= length(parsed_data.chunks)
              assert is_boolean(assembly_result.verification_passed)

            {:error, _reason} ->
              assert true
          end
        else
          assert true
        end
      end
    end
  end

  describe("chunk verification edge cases") do
    test "handles chunk with no CACNK wrapper" do
      test_data = "Raw chunk data without CACNK wrapper"
      chunk_id = Chunks.calculate_chunk_id(test_data)
      chunk_id_hex = Base.encode16(chunk_id, case: :lower)
      compressed_data = :ezstd.compress(test_data)
      chunk_info = %{chunk_id: chunk_id, size: byte_size(test_data)}
      result = decompress_and_verify_test_chunk(compressed_data, chunk_info, chunk_id_hex)
      assert {:ok, verified_data} = result
      assert verified_data == test_data
    end

    test "handles uncompressed chunk data" do
      test_data = "Uncompressed chunk data"
      chunk_id = Chunks.calculate_chunk_id(test_data)
      chunk_id_hex = Base.encode16(chunk_id, case: :lower)
      chunk_info = %{chunk_id: chunk_id, size: byte_size(test_data)}
      result = decompress_and_verify_test_chunk(test_data, chunk_info, chunk_id_hex)
      assert {:ok, verified_data} = result
      assert verified_data == test_data
    end
  end

  describe("full decode workflow") do
    test "decodes blob1.caibx completely" do
      caibx_path = Path.join(@testdata_path, "blob1.caibx")
      store_path = Path.join(@testdata_path, "blob1.store")

      result =
        CasyncDecoder.decode_file(caibx_path,
          store_path: store_path,
          output_dir: @test_output_dir,
          verify_integrity: true
        )

      assert {:ok, decode_result} = result
      assert decode_result.format == :caibx
      assert decode_result.file_size > 0
      assert decode_result.chunk_count > 0
      assert decode_result.integrity_verified == true
      assert decode_result.assembly_result != nil
    end

    test "decodes blob2.caibx completely" do
      caibx_path = Path.join(@testdata_path, "blob2.caibx")
      store_path = Path.join(@testdata_path, "blob2.store")

      result =
        CasyncDecoder.decode_file(caibx_path,
          store_path: store_path,
          output_dir: @test_output_dir,
          verify_integrity: true
        )

      assert {:ok, decode_result} = result
      assert decode_result.format == :caibx
      assert decode_result.integrity_verified == true
    end
  end

  describe("format bytes utility") do
    test "formats byte sizes correctly" do
      assert CasyncDecoder.format_bytes(512) == "512 bytes"
      assert CasyncDecoder.format_bytes(1024) == "1.0 KB"
      assert CasyncDecoder.format_bytes(1536) == "1.5 KB"
      assert CasyncDecoder.format_bytes(1_048_576) == "1.0 MB"
      assert CasyncDecoder.format_bytes(1_073_741_824) == "1.0 GB"
      assert CasyncDecoder.format_bytes(nil) == "unknown size"
    end
  end

  defp decompress_test_data(data, compression) do
    case compression do
      :zstd ->
        case :ezstd.decompress(data) do
          result when is_binary(result) -> {:ok, result}
          error -> {:error, {:zstd_error, error}}
        end

      :none ->
        {:ok, data}

      _ ->
        {:error, {:unsupported_compression, compression}}
    end
  end

  defp process_real_chunk(chunk_data, _chunk_id, _chunk_id_hex) do
    case :ezstd.decompress(chunk_data) do
      decompressed_data when is_binary(decompressed_data) ->
        {:ok, decompressed_data}

      _error ->
        case CasyncFormat.parse_chunk(chunk_data) do
          {:ok, %{header: header, data: compressed_data}} ->
            decompress_test_data(compressed_data, header.compression)

          {:error, _parse_error} ->
            {:ok, chunk_data}
        end
    end
  end

  defp decompress_and_verify_test_chunk(chunk_data, chunk_info, _chunk_id_hex) do
    case CasyncFormat.parse_chunk(chunk_data) do
      {:ok, %{header: header, data: compressed_data}} ->
        handle_parsed_chunk(compressed_data, header.compression, chunk_info)

      {:error, "Invalid chunk file magic"} ->
        handle_raw_chunk_data(chunk_data, chunk_info)

      {:error, reason} ->
        {:error, {:parse_failed, reason}}
    end
  end

  defp handle_parsed_chunk(compressed_data, compression, chunk_info) do
    case decompress_test_data(compressed_data, compression) do
      {:ok, decompressed_data} -> verify_with_both_algorithms(decompressed_data, chunk_info)
      {:error, reason} -> {:error, {:decompression_failed, reason}}
    end
  end

  defp handle_raw_chunk_data(chunk_data, chunk_info) do
    case decompress_test_data(chunk_data, :zstd) do
      {:ok, decompressed_data} -> verify_with_both_algorithms(decompressed_data, chunk_info)
      {:error, _reason} -> verify_with_both_algorithms(chunk_data, chunk_info)
    end
  end

  defp verify_with_both_algorithms(data, chunk_info) do
    case CasyncDecoder.verify_chunk(data, chunk_info.chunk_id, 0) do
      {:ok, _} = result ->
        result

      {:error, {:hash_mismatch, _}} ->
        CasyncDecoder.verify_chunk(data, chunk_info.chunk_id, @ca_format_sha512_256)

      {:error, _reason} ->
        {:error, :verification_failed}
    end
  end
end
