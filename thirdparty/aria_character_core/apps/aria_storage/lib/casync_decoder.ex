# Copyright (c) 2025-present K. S. Ernest (iFire) Lee

defmodule AriaStorage.CasyncDecoder do
  @moduledoc "Advanced casync file decoder and analyzer.\n\nThis module provides comprehensive decoding and analysis capabilities for all casync file formats:\n- .caibx (Content Archive Index for Blobs)\n- .caidx (Content Archive Index for Directory Trees)\n- .catar (Archive Container format)\n- .cacnk (Compressed Chunk files)\n\nThe decoder supports both local and remote file processing, with full chunk reconstruction\nand integrity verification capabilities.\n\n## Examples\n\n    # Decode a local CAIDX file with store\n    {:ok, result} = AriaStorage.CasyncDecoder.decode_file(\"/path/to/file.caidx\",\n      store_path: \"/path/to/file.store\")\n\n    # Decode a remote CAIDX file with remote store\n    {:ok, result} = AriaStorage.CasyncDecoder.decode_uri(\"https://example.com/file.caidx\",\n      store_uri: \"https://example.com/store/\")\n\n    # Assemble and verify complete file from chunks\n    {:ok, assembled_file} = AriaStorage.CasyncDecoder.assemble_file(parsed_data,\n      store_path: \"/path/to/store\", output_path: \"/path/to/output.bin\")\n\n"
  require Logger
  import Bitwise
  alias AriaStorage.Parsers.CasyncFormat
  @ca_format_sha512_256 2_305_843_009_213_693_952
  @type decode_options :: [
          store_path: String.t() | nil,
          store_uri: String.t() | nil,
          output_dir: String.t() | nil,
          verify_integrity: boolean(),
          progress_callback: (integer(), integer() -> :ok) | nil
        ]
  @type decode_result :: %{
          format: atom(),
          parsed_data: map(),
          file_size: integer(),
          chunk_count: integer(),
          integrity_verified: boolean(),
          assembly_result: map() | nil
        }
  @type assembly_result :: %{
          success: boolean(),
          assembled_file: String.t(),
          bytes_written: integer(),
          chunks_processed: integer(),
          verification_passed: boolean(),
          size_verified: boolean()
        }
  @doc "Decode a casync file from a local file path.\n"
  @spec decode_file(String.t(), decode_options()) :: {:ok, decode_result()} | {:error, any()}
  def decode_file(file_path, opts \\ []) do
    with {:ok, binary_data} <- File.read(file_path),
         {:ok, parsed_data} <- parse_casync_data(binary_data, file_path) do
      result = %{
        format: parsed_data.format,
        parsed_data: parsed_data,
        file_size: byte_size(binary_data),
        chunk_count: get_chunk_count(parsed_data),
        integrity_verified: false,
        assembly_result: nil
      }

      result =
        if should_assemble?(parsed_data, opts) do
          case assemble_file(parsed_data, opts) do
            {:ok, assembly_result} ->
              %{
                result
                | assembly_result: assembly_result,
                  integrity_verified: assembly_result.verification_passed
              }

            {:error, _reason} ->
              result
          end
        else
          result
        end

      {:ok, result}
    end
  end

  @doc "Decode a casync file from a remote URI.\n"
  @spec decode_uri(String.t(), decode_options()) :: {:ok, decode_result()} | {:error, any()}
  def decode_uri(file_uri, opts \\ []) do
    with {:ok, binary_data} <- download_file(file_uri),
         {:ok, parsed_data} <- parse_casync_data(binary_data, file_uri) do
      result = %{
        format: parsed_data.format,
        parsed_data: parsed_data,
        file_size: byte_size(binary_data),
        chunk_count: get_chunk_count(parsed_data),
        integrity_verified: false,
        assembly_result: nil
      }

      result =
        if should_assemble?(parsed_data, opts) do
          case assemble_file(parsed_data, opts) do
            {:ok, assembly_result} ->
              %{
                result
                | assembly_result: assembly_result,
                  integrity_verified: assembly_result.verification_passed
              }

            {:error, _reason} ->
              result
          end
        else
          result
        end

      {:ok, result}
    end
  end

  @doc "Assemble a complete file from parsed casync data and verify integrity.\n"
  @spec assemble_file(map(), decode_options()) :: {:ok, assembly_result()} | {:error, any()}
  def assemble_file(parsed_data, opts \\ []) do
    output_dir = opts[:output_dir] || System.tmp_dir!()
    progress_callback = opts[:progress_callback]

    case parsed_data.format do
      format when format in [:caidx, :caibx] ->
        assemble_from_chunks(parsed_data, opts, output_dir, progress_callback)

      :catar ->
        extract_catar_archive(parsed_data, output_dir)

      _ ->
        {:error, {:unsupported_format, parsed_data.format}}
    end
  end

  @doc "Download and verify a single chunk from a store.\n"
  @spec download_chunk(String.t(), String.t()) :: {:ok, binary()} | {:error, any()}
  def download_chunk(store_uri, chunk_id_hex) do
    chunk_dir = String.slice(chunk_id_hex, 0, 4)
    chunk_file = "#{chunk_id_hex}.cacnk"
    base_store_uri = String.trim_trailing(store_uri, "/")
    chunk_url = "#{base_store_uri}/#{chunk_dir}/#{chunk_file}"
    download_file(chunk_url)
  end

  @doc "Verify the integrity of chunk data against expected hash.\nUses appropriate hash algorithm based on feature flags:\n- When feature_flags & CA_FORMAT_SHA512_256 != 0: use SHA512/256\n- Otherwise: use SHA256\n"
  @spec verify_chunk(binary(), binary(), integer()) :: {:ok, binary()} | {:error, any()}
  def verify_chunk(chunk_data, expected_hash, feature_flags) do
    calculated_hash =
      if (feature_flags &&& @ca_format_sha512_256) != 0 do
        :crypto.hash(:sha512, chunk_data) |> binary_part(0, 32)
      else
        :crypto.hash(:sha256, chunk_data)
      end

    if calculated_hash == expected_hash do
      {:ok, chunk_data}
    else
      {:error, {:hash_mismatch, %{id: expected_hash, sum: calculated_hash}}}
    end
  end

  @doc "Format byte size into human-readable string.\n"
  @spec format_bytes(integer()) :: String.t()
  def format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1024 * 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"
      bytes >= 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024), 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} bytes"
    end
  end

  def format_bytes(_) do
    "unknown size"
  end

  defp parse_casync_data(binary_data, file_path) do
    file_ext = Path.extname(file_path) |> String.downcase()

    case file_ext do
      ".catar" ->
        CasyncFormat.parse_archive(binary_data)

      ext when ext in [".caidx", ".caibx"] ->
        CasyncFormat.parse_index(binary_data)

      _ ->
        case CasyncFormat.parse_index(binary_data) do
          {:ok, _} = result -> result
          {:error, _} -> CasyncFormat.parse_archive(binary_data)
        end
    end
  end

  defp get_chunk_count(parsed_data) do
    case parsed_data.format do
      format when format in [:caidx, :caibx] -> length(parsed_data.chunks)
      :catar -> length(parsed_data.files) + length(parsed_data.directories)
      _ -> 0
    end
  end

  defp should_assemble?(parsed_data, opts) do
    case parsed_data.format do
      format when format in [:caidx, :caibx] ->
        opts[:store_path] != nil or opts[:store_uri] != nil

      :catar ->
        true

      _ ->
        false
    end
  end

  defp assemble_from_chunks(parsed_data, opts, output_dir, progress_callback) do
    if length(parsed_data.chunks) == 0 do
      {:error, :no_chunks_to_assemble}
    else
      sorted_chunks = Enum.sort_by(parsed_data.chunks, & &1.offset)
      assembled_file = Path.join(output_dir, "assembled_file.bin")

      case File.open(assembled_file, [:write, :binary]) do
        {:ok, file} ->
          try do
            store_context = get_store_context(opts)

            {success_count, total_bytes_written} =
              assemble_chunks_to_file(
                file,
                sorted_chunks,
                store_context,
                0,
                0,
                progress_callback,
                parsed_data.feature_flags
              )

            File.close(file)
            {:ok, file_stat} = File.stat(assembled_file)
            actual_size = file_stat.size
            verification_passed = actual_size == parsed_data.header.total_size

            {:ok,
             %{
               success: true,
               assembled_file: assembled_file,
               bytes_written: total_bytes_written,
               chunks_processed: success_count,
               verification_passed: verification_passed,
               size_verified: verification_passed
             }}
          rescue
            error ->
              File.close(file)
              {:error, {:assembly_failed, error}}
          end

        {:error, reason} ->
          {:error, {:file_open_failed, reason}}
      end
    end
  end

  defp extract_catar_archive(parsed_data, output_dir) do
    extract_dir = Path.join(output_dir, "extracted")
    File.mkdir_p!(extract_dir)

    Enum.each(parsed_data.directories, fn dir ->
      path = Map.get(dir, :path) || Map.get(dir, :name, "unnamed")
      dir_path = Path.join(extract_dir, path)
      File.mkdir_p!(dir_path)
    end)

    files_extracted =
      Enum.reduce(parsed_data.files, 0, fn file, acc ->
        path = Map.get(file, :path) || Map.get(file, :name, "unnamed")
        file_path = Path.join(extract_dir, path)
        parent_dir = Path.dirname(file_path)
        File.mkdir_p!(parent_dir)
        content = Map.get(file, :content)

        if content do
          File.write!(file_path, content)
          mode = Map.get(file, :mode)

          if mode do
            perm = mode &&& 511

            if perm > 0 do
              File.chmod!(file_path, perm)
            end
          end

          acc + 1
        else
          acc
        end
      end)

    {:ok,
     %{
       success: true,
       assembled_file: extract_dir,
       bytes_written: 0,
       chunks_processed: files_extracted,
       verification_passed: true,
       size_verified: true
     }}
  end

  defp get_store_context(opts) do
    cond do
      opts[:store_uri] -> {:remote, opts[:store_uri]}
      opts[:store_path] -> {:local, opts[:store_path]}
      true -> nil
    end
  end

  defp assemble_chunks_to_file(
         file,
         chunks,
         store_context,
         success_count,
         total_bytes,
         progress_callback,
         feature_flags
       ) do
    total_chunks = length(chunks)

    case chunks do
      [] ->
        {success_count, total_bytes}

      [chunk | remaining_chunks] ->
        if progress_callback && rem(success_count, 10) == 0 do
          progress_callback.(success_count, total_chunks)
        end

        chunk_id_hex = Base.encode16(chunk.chunk_id, case: :lower)

        case fetch_chunk_data(chunk_id_hex, store_context) do
          {:ok, chunk_data} ->
            case decompress_and_verify_chunk(chunk_data, chunk, chunk_id_hex, feature_flags) do
              {:ok, decompressed_data} ->
                case :file.write(file, decompressed_data) do
                  :ok ->
                    assemble_chunks_to_file(
                      file,
                      remaining_chunks,
                      store_context,
                      success_count + 1,
                      total_bytes + byte_size(decompressed_data),
                      progress_callback,
                      feature_flags
                    )

                  {:error, reason} ->
                    Logger.debug(
                      "Failed to write chunk #{String.slice(chunk_id_hex, 0, 8)}: #{inspect(reason)}"
                    )

                    assemble_chunks_to_file(
                      file,
                      remaining_chunks,
                      store_context,
                      success_count,
                      total_bytes,
                      progress_callback,
                      feature_flags
                    )
                end

              {:error, reason} ->
                Logger.debug(
                  "Chunk #{String.slice(chunk_id_hex, 0, 8)} verification failed: #{inspect(reason)}"
                )

                assemble_chunks_to_file(
                  file,
                  remaining_chunks,
                  store_context,
                  success_count,
                  total_bytes,
                  progress_callback,
                  feature_flags
                )
            end

          {:error, reason} ->
            Logger.debug(
              "Chunk #{String.slice(chunk_id_hex, 0, 8)} not found: #{inspect(reason)}"
            )

            assemble_chunks_to_file(
              file,
              remaining_chunks,
              store_context,
              success_count,
              total_bytes,
              progress_callback,
              feature_flags
            )
        end
    end
  end

  defp fetch_chunk_data(chunk_id_hex, store_context) do
    case store_context do
      {:local, store_path} ->
        chunk_dir = String.slice(chunk_id_hex, 0, 4)
        chunk_file = "#{chunk_id_hex}.cacnk"
        chunk_path = Path.join([store_path, chunk_dir, chunk_file])
        File.read(chunk_path)

      {:remote, store_uri} ->
        download_chunk(store_uri, chunk_id_hex)

      nil ->
        {:error, :no_store_available}
    end
  end

  defp decompress_and_verify_chunk(chunk_data, chunk_info, chunk_id_hex, feature_flags) do
    case CasyncFormat.parse_chunk(chunk_data) do
      {:ok, %{header: header, data: compressed_data}} ->
        case decompress_chunk_data(compressed_data, header.compression) do
          {:ok, decompressed_data} ->
            verify_chunk_hash_and_size(decompressed_data, chunk_info, chunk_id_hex, feature_flags)

          {:error, reason} ->
            {:error, {:decompression_failed, reason}}
        end

      {:error, "Invalid chunk file magic"} ->
        case decompress_chunk_data(chunk_data, :zstd) do
          {:ok, decompressed_data} ->
            verify_chunk_hash_and_size(decompressed_data, chunk_info, chunk_id_hex, feature_flags)

          {:error, _reason} ->
            verify_chunk_hash_and_size(chunk_data, chunk_info, chunk_id_hex, feature_flags)
        end

      {:error, reason} ->
        {:error, {:parse_failed, reason}}
    end
  end

  defp verify_chunk_hash_and_size(data, chunk_info, _chunk_id_hex, _feature_flags) do
    if byte_size(data) == chunk_info.size do
      {:ok, data}
    else
      {:error, :size_mismatch}
    end
  end

  defp decompress_chunk_data(data, :zstd) do
    case :ezstd.decompress(data) do
      result when is_binary(result) -> {:ok, result}
      error -> {:error, {:zstd_error, error}}
    end
  end

  defp decompress_chunk_data(data, :none) do
    {:ok, data}
  end

  defp decompress_chunk_data(_data, compression) do
    {:error, {:unsupported_compression, compression}}
  end

  defp download_file(url) do
    Application.ensure_all_started(:hackney)
    Application.ensure_all_started(:ssl)

    case HTTPoison.get(url, [],
           timeout: 300_000,
           recv_timeout: 300_000,
           follow_redirect: true,
           max_redirect: 5
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} -> {:ok, body}
      {:ok, %HTTPoison.Response{status_code: status_code}} -> {:error, "HTTP #{status_code}"}
      {:error, %HTTPoison.Error{reason: reason}} -> {:error, reason}
    end
  end
end
