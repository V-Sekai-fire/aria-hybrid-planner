# Copyright (c) 2025-present K. S. Ernest (iFire) Lee

defmodule AriaStorage.WaffleChunkStore do
  @moduledoc "Waffle-based chunk store for desync compatibility.\n\nThis module integrates Waffle's file storage capabilities with our\ndesync chunking system, providing a flexible storage backend that\ncan work with local filesystem, S3, or other Waffle-supported backends.\n"
  use Waffle.Definition
  use Waffle.Ecto.Definition
  alias AriaStorage.Chunks
  @versions [:original]
  def bucket do
    Application.get_env(:aria_storage, :waffle_bucket, "aria-chunks")
  end

  def validate({file, _}) do
    case File.read(file.path) do
      {:ok, _data} -> true
      {:error, _} -> false
    end
  end

  def filename(version, {_file, %{chunk_id: chunk_id}}) when version == :original do
    chunk_id <> ".cacnk"
  end

  def filename(version, {file, _scope}) when version == :original do
    Path.basename(file.file_name, Path.extname(file.file_name)) <> ".cacnk"
  end

  def storage_dir(version, {_file, %{chunk_id: chunk_id}}) when version == :original do
    <<prefix::binary-size(2), _rest::binary>> = chunk_id
    "chunks/#{prefix}"
  end

  def storage_dir(version, {_file, _scope}) when version == :original do
    "chunks/misc"
  end

  def default_url(version) when version == :original do
    "/chunks/missing.cacnk"
  end

  def transform(:original, _) do
    :noaction
  end

  @doc "Stores a chunk using Waffle with proper metadata.\n"
  def store_chunk(%Chunks{} = chunk, _opts \\ []) do
    scope = %{
      chunk_id: Base.encode16(chunk.id, case: :lower),
      size: chunk.size,
      compressed: chunk.compressed != nil
    }

    temp_file = create_temp_chunk_file(chunk)

    try do
      case store({temp_file, scope}) do
        {:ok, file_path} ->
          {:ok,
           %{
             path: file_path,
             url: url({file_path, scope}),
             chunk_id: scope.chunk_id,
             size: chunk.size
           }}

        {:error, reason} ->
          {:error, {:waffle_store_failed, reason}}
      end
    after
      File.rm(temp_file)
    end
  end

  @doc "Retrieves a chunk from Waffle storage.\n"
  def retrieve_chunk(chunk_id, _opts \\ []) when is_binary(chunk_id) do
    scope = %{chunk_id: chunk_id}
    file_path = url({nil, scope}, signed: true)

    case download_chunk_file(file_path) do
      {:ok, compressed_data} ->
        case Chunks.decompress_chunk(compressed_data, :zstd) do
          {:ok, data} ->
            chunk_id_binary = Base.decode16!(chunk_id, case: :lower)

            {:ok,
             %Chunks{
               id: chunk_id_binary,
               data: data,
               size: byte_size(data),
               compressed: compressed_data,
               checksum: :crypto.hash(:sha256, data)
             }}

          {:error, _} = error ->
            error
        end

      {:error, reason} ->
        {:error, {:chunk_retrieval_failed, reason}}
    end
  end

  @doc "Lists all chunks in the storage backend.\n"
  def list_chunks(opts \\ []) do
    case get_storage_backend() do
      :s3 -> list_chunks_s3(opts)
      :local -> list_chunks_local(opts)
      backend -> {:error, {:unsupported_backend, backend}}
    end
  end

  @doc "Deletes a chunk from storage.\n"
  def delete_chunk(chunk_id) when is_binary(chunk_id) do
    scope = %{chunk_id: chunk_id}

    case delete({nil, scope}) do
      :ok -> :ok
    end
  end

  @doc "Checks if a chunk exists in storage.\n"
  def chunk_exists?(chunk_id) when is_binary(chunk_id) do
    scope = %{chunk_id: chunk_id}
    file_path = url({nil, scope})

    case get_storage_backend() do
      :s3 -> chunk_exists_s3?(file_path)
      :local -> chunk_exists_local?(file_path)
      _ -> false
    end
  end

  defp create_temp_chunk_file(%Chunks{} = chunk) do
    data = chunk.compressed || chunk.data
    temp_path = System.tmp_dir!() |> Path.join("chunk_#{System.unique_integer([:positive])}.tmp")
    File.write!(temp_path, data)
    temp_path
  end

  defp download_chunk_file(file_path) do
    case get_storage_backend() do
      :s3 -> download_chunk_s3(file_path)
      :local -> download_chunk_local(file_path)
      backend -> {:error, {:unsupported_backend, backend}}
    end
  end

  defp get_storage_backend do
    Application.get_env(:waffle, :storage, Waffle.Storage.Local)
    |> case do
      Waffle.Storage.S3 -> :s3
      Waffle.Storage.Local -> :local
      _ -> :unknown
    end
  end

  defp list_chunks_s3(opts) do
    bucket = bucket()
    prefix = Keyword.get(opts, :prefix, "chunks/")

    case ExAws.S3.list_objects(bucket, prefix: prefix) |> ExAws.request() do
      {:ok, %{body: %{contents: objects}}} ->
        chunk_ids =
          objects
          |> Enum.map(& &1.key)
          |> Enum.filter(&String.ends_with?(&1, ".cacnk"))
          |> Enum.map(&extract_chunk_id_from_path/1)
          |> Enum.reject(&is_nil/1)

        {:ok, chunk_ids}

      {:error, reason} ->
        {:error, {:s3_list_failed, reason}}
    end
  end

  defp chunk_exists_s3?(file_path) do
    bucket = bucket()
    key = extract_s3_key(file_path)

    case ExAws.S3.head_object(bucket, key) |> ExAws.request() do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp download_chunk_s3(file_path) do
    bucket = bucket()
    key = extract_s3_key(file_path)

    case ExAws.S3.get_object(bucket, key) |> ExAws.request() do
      {:ok, %{body: data}} -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_s3_key(file_path) do
    URI.parse(file_path).path |> String.trim_leading("/")
  end

  defp list_chunks_local(opts) do
    storage_path = get_local_storage_path()
    prefix = Keyword.get(opts, :prefix, "chunks")
    search_path = Path.join(storage_path, prefix)

    case File.ls(search_path) do
      {:ok, files} ->
        chunk_ids =
          files
          |> Enum.filter(&String.ends_with?(&1, ".cacnk"))
          |> Enum.map(&extract_chunk_id_from_path/1)
          |> Enum.reject(&is_nil/1)

        {:ok, chunk_ids}

      {:error, reason} ->
        {:error, {:local_list_failed, reason}}
    end
  end

  defp chunk_exists_local?(file_path) do
    File.exists?(file_path)
  end

  defp download_chunk_local(file_path) do
    case File.read(file_path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_local_storage_path do
    Application.get_env(:waffle, Waffle.Storage.Local)[:storage_dir] ||
      Path.join(File.cwd!(), "uploads")
  end

  defp extract_chunk_id_from_path(file_path) do
    file_path
    |> Path.basename(".cacnk")
    |> case do
      ^file_path -> nil
      chunk_id -> chunk_id
    end
  end
end
