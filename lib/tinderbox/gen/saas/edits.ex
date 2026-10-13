defmodule Tinderbox.Gen.Saas.Edits do
  @moduledoc """
  Small, idempotent zipper edits for files the Phoenix and Ash installers wrote.

  Every function here is a no-op when there is nothing to do (the call is gone,
  the code is already in place), so a generator that uses them can be re-run.
  A module that does not exist is left alone rather than raised on: the
  installer that would have created it may have been skipped.
  """

  alias Igniter.Code.Common
  alias Igniter.Code.Function
  alias Sourceror.Zipper

  @doc """
  Removes every call to `name` (with one of `arities`) from `module`, searching
  the whole module body, including nested `scope`/`policy` blocks.

  `matches?` receives the zipper on a candidate call and decides whether it goes.
  """
  @spec remove_call(Igniter.t(), module(), atom(), [non_neg_integer()], (Zipper.t() -> boolean())) ::
          Igniter.t()
  def remove_call(igniter, module, name, arities, matches? \\ fn _zipper -> true end) do
    update_existing(igniter, module, fn zipper ->
      {:ok,
       Common.remove(zipper, fn candidate ->
         Function.function_call?(candidate, name, arities) and matches?.(candidate)
       end)}
    end)
  end

  @doc """
  Removes the `policy always() do forbid_if always() end` catch-all the
  AshAuthentication installer puts on the user resource, and nothing else: a
  `policy always()` with any other body stays.
  """
  @spec remove_forbid_all_policy(Igniter.t(), module()) :: Igniter.t()
  def remove_forbid_all_policy(igniter, resource) do
    remove_call(igniter, resource, :policy, [1, 2], fn candidate ->
      squish(candidate.node) == "policy always() do forbid_if always() end"
    end)
  end

  @doc """
  Inserts `code` (a `plug …` line) immediately before the endpoint's
  `plug <anchor>` line. A no-op when the endpoint already plugs the same module,
  or has no `plug <anchor>` to insert before.
  """
  @spec insert_before_plug(Igniter.t(), module(), module(), String.t()) :: Igniter.t()
  def insert_before_plug(igniter, endpoint, anchor, code) do
    inserted = plug_module(code)

    update_existing(igniter, endpoint, fn zipper ->
      cond do
        plugs?(zipper, inserted) ->
          {:ok, zipper}

        true ->
          case find_plug(zipper, anchor) do
            {:ok, at_anchor} ->
              {:ok, Common.add_code(at_anchor, code, placement: :before)}

            :error ->
              {:warning,
               "#{inspect(endpoint)} has no `plug #{inspect(anchor)}`; add `#{code}` by hand."}
          end
      end
    end)
  end

  @doc """
  Inserts `code` as the first statements of `module`'s `start/2` (the
  application callback). A no-op when the module already contains the first line
  of `code`.
  """
  @spec prepend_to_start(Igniter.t(), module(), String.t()) :: Igniter.t()
  def prepend_to_start(igniter, module, code) do
    first_line = code |> String.split("\n", trim: true) |> hd() |> String.trim()

    update_existing(igniter, module, fn zipper ->
      # `move_to_def/3` already lands inside the function body.
      with false <- contains?(zipper, first_line),
           {:ok, body} <- Function.move_to_def(zipper, :start, 2) do
        {:ok, add_before_first_statement(body, code)}
      else
        true ->
          {:ok, zipper}

        _ ->
          {:warning,
           "Could not find `start/2` in #{inspect(module)}; add `#{first_line}` by hand."}
      end
    end)
  end

  @doc """
  Inserts `child` (a child spec as code, e.g. `"FunWithFlags.Supervisor"`)
  into the application's `children = [...]` list immediately after the child
  that starts `anchor`. A no-op when the module already supervises `child`, and
  a warning when the list or the anchor is not there.

  `Igniter.Project.Application.add_new_child/3` cannot do this: its `after:`
  option places a child after the neighbour of the last module it names, which
  is not where the caller asked for it.
  """
  @spec add_child_after(Igniter.t(), module(), module(), String.t(), module()) :: Igniter.t()
  def add_child_after(igniter, application, module, child, anchor) do
    {igniter, present?} = source_contains?(igniter, application, inspect(module))

    if present? do
      igniter
    else
      update_existing(igniter, application, fn zipper ->
        with {:ok, body} <- Function.move_to_def(zipper, :start, 2),
             {:ok, assignment} <-
               Function.move_to_function_call_in_current_scope(body, :=, 2, &children?/1),
             {:ok, list} <- Function.move_to_nth_argument(assignment, 1),
             {:ok, item} <- Igniter.Code.List.move_to_list_item(list, &starts?(&1, anchor)) do
          {:ok, Zipper.insert_right(item, Sourceror.parse_string!(child))}
        else
          _ ->
            {:warning,
             "Could not add `#{child}` after #{inspect(anchor)} in the children of " <>
               "#{inspect(application)}. Add it by hand."}
        end
      end)
    end
  end

  defp children?(call) do
    match?(
      {:ok, %Zipper{node: {:children, _meta, context}}} when is_atom(context),
      Function.move_to_nth_argument(call, 0)
    )
  end

  # `Module` and `{Module, opts}` children both start `Module`.
  defp starts?(item, module) do
    head =
      if Igniter.Code.Tuple.tuple?(item) do
        case Igniter.Code.Tuple.tuple_elem(item, 0) do
          {:ok, head} -> head
          :error -> item
        end
      else
        item
      end

    Common.nodes_equal?(head, module)
  end

  @doc """
  Appends `code` after the last top-level statement of `module`. The caller
  guards against appending twice (see `source_contains?/3`).
  """
  @spec append_to_module(Igniter.t(), module(), String.t()) :: Igniter.t()
  def append_to_module(igniter, module, code) do
    update_existing(igniter, module, fn body ->
      {:ok, body |> last_statement() |> Common.add_code(code, placement: :after)}
    end)
  end

  @doc """
  Makes `attribute :<name>` on an Ash resource accept `nil`: flips (or adds)
  `allow_nil? true` in the attribute's options. A no-op when it already does.

  The password strategy installer declares `hashed_password` with
  `allow_nil? false`, which a user who only ever signs in with SSO cannot satisfy.
  """
  @spec make_attribute_nullable(Igniter.t(), module(), atom()) :: Igniter.t()
  def make_attribute_nullable(igniter, resource, name) do
    update_existing(igniter, resource, fn zipper ->
      with {:ok, attributes} <-
             Function.move_to_function_call_in_current_scope(zipper, :attributes, 1),
           {:ok, block} <- Common.move_to_do_block(attributes),
           {:ok, attribute} <-
             Function.move_to_function_call_in_current_scope(
               block,
               :attribute,
               [2, 3],
               &Function.argument_equals?(&1, 0, name)
             ),
           {:ok, zipper} <- set_allow_nil(attribute) do
        {:ok, zipper}
      else
        _ -> {:warning, "Could not find `attribute :#{name}` in #{inspect(resource)}."}
      end
    end)
  end

  @doc """
  Appends `value` to the list given to `option` inside nested DSL sections of an
  Ash resource, unless it is in the list already: with
  `sections = [:authentication, :add_ons, :confirmation]` and
  `option = :auto_confirm_actions` this edits

      authentication do
        add_ons do
          confirmation :confirm_new_user do
            auto_confirm_actions [:reset_password_with_token]
  """
  @spec append_to_option_list(Igniter.t(), module(), [atom()], atom(), term()) :: Igniter.t()
  def append_to_option_list(igniter, resource, sections, option, value) do
    update_existing(igniter, resource, fn zipper ->
      with {:ok, inside} <- enter_sections(zipper, sections),
           {:ok, call} <- Function.move_to_function_call_in_current_scope(inside, option, 1),
           {:ok, list} <- Function.move_to_nth_argument(call, 0),
           {:ok, list} <- Igniter.Code.List.append_new_to_list(list, value) do
        {:ok, list}
      else
        _ ->
          {:warning,
           "Could not add #{inspect(value)} to `#{option}` in #{inspect(resource)}; " <>
             "add it by hand."}
      end
    end)
  end

  defp enter_sections(zipper, []), do: {:ok, zipper}

  defp enter_sections(zipper, [section | rest]) do
    with {:ok, call} <- Function.move_to_function_call_in_current_scope(zipper, section, [1, 2]),
         {:ok, body} <- Common.move_to_do_block(call) do
      enter_sections(body, rest)
    end
  end

  @doc """
  Whether `module`'s current source (including edits queued on the igniter)
  contains `snippet`. The guard for edits that have no better "already there"
  test, such as adding a route or a policy.

  Parentheses and whitespace are ignored on both sides: a project that does not
  `import_deps` Ash or Phoenix writes `live("/x", Y)` where one that does writes
  `live "/x", Y`, and the guard must hold for both.
  """
  @spec source_contains?(Igniter.t(), module(), String.t()) :: {Igniter.t(), boolean()}
  def source_contains?(igniter, module, snippet) do
    case Igniter.Project.Module.find_module(igniter, module) do
      {:ok, {igniter, source, _zipper}} ->
        content = Rewrite.Source.get(source, :content)
        {igniter, String.contains?(flatten(content), flatten(snippet))}

      {:error, igniter} ->
        {igniter, false}
    end
  end

  @doc """
  Drops the notices that mention `snippet`. For an installer's advice the
  generator has already acted on.
  """
  @spec drop_notices(Igniter.t(), String.t()) :: Igniter.t()
  def drop_notices(igniter, snippet) do
    %{igniter | notices: Enum.reject(igniter.notices, &String.contains?(&1, snippet))}
  end

  @doc """
  Applies `fun` to the content of the file at `path`: `{:ok, new_content}`
  rewrites it, `{:warning, message}` leaves it and warns. A missing file is
  warned about.
  """
  @spec update_file(Igniter.t(), Path.t(), (String.t() ->
                                              {:ok, String.t()} | {:warning, String.t()})) ::
          Igniter.t()
  def update_file(igniter, path, fun) do
    if Igniter.exists?(igniter, path) do
      igniter = Igniter.include_existing_file(igniter, path)
      source = Rewrite.source!(igniter.rewrite, path)

      case fun.(Rewrite.Source.get(source, :content)) do
        {:ok, content} -> Igniter.update_file(igniter, path, &set_content(&1, igniter, content))
        {:warning, message} -> Igniter.add_warning(igniter, message)
      end
    else
      Igniter.add_warning(igniter, "#{path} does not exist, so it was not edited.")
    end
  end

  defp flatten(code), do: code |> String.replace(["(", ")"], " ") |> String.replace(~r/\s+/, " ")

  # --- internals ----------------------------------------------------------

  defp update_existing(igniter, module, fun) do
    case Igniter.Project.Module.module_exists(igniter, module) do
      {true, igniter} -> Igniter.Project.Module.find_and_update_module!(igniter, module, fun)
      {false, igniter} -> igniter
    end
  end

  defp set_content(source, igniter, content) do
    if Rewrite.Source.get(source, :content) == content do
      source
    else
      Igniter.update_source(source, igniter, :content, content)
    end
  end

  # `allow_nil?` lives in the attribute's do block, or in its options keyword
  # when it has no block (`attribute :x, :string, allow_nil?: false`).
  defp set_allow_nil(attribute) do
    case Common.move_to_do_block(attribute) do
      {:ok, body} ->
        case Function.move_to_function_call_in_current_scope(body, :allow_nil?, 1) do
          {:ok, call} -> {:ok, Common.replace_code(call, "allow_nil? true")}
          :error -> {:ok, Common.add_code(body, "allow_nil? true", placement: :before)}
        end

      :error ->
        Function.update_nth_argument(attribute, 2, fn options ->
          Igniter.Code.Keyword.set_keyword_key(options, :allow_nil?, true, fn value ->
            {:ok, Common.replace_code(value, "true")}
          end)
        end)
    end
  end

  # `body` is the function's block of statements, or its only statement.
  defp add_before_first_statement(%Zipper{node: {:__block__, _meta, [_ | _]}} = body, code) do
    body |> Zipper.down() |> add_before(code)
  end

  defp add_before_first_statement(body, code), do: add_before(body, code)

  defp last_statement(%Zipper{node: {:__block__, _meta, [_ | _]}} = body),
    do: body |> Zipper.down() |> Zipper.rightmost()

  defp last_statement(body), do: body

  defp add_before(zipper, code), do: Common.add_code(zipper, code, placement: :before)

  defp find_plug(zipper, module) do
    Function.move_to_function_call_in_current_scope(
      zipper,
      :plug,
      [1, 2],
      &Function.argument_equals?(&1, 0, module)
    )
  end

  defp plugs?(_zipper, nil), do: false
  defp plugs?(zipper, module), do: match?({:ok, _}, find_plug(zipper, module))

  defp plug_module(code) do
    case Code.string_to_quoted!(code) do
      {:plug, _meta, [{:__aliases__, _meta2, parts} | _opts]} -> Module.concat(parts)
      _other -> nil
    end
  end

  defp contains?(zipper, snippet) do
    zipper |> Zipper.topmost_root() |> Sourceror.to_string() |> String.contains?(snippet)
  end

  defp squish(node), do: node |> Sourceror.to_string() |> String.replace(~r/\s+/, " ")
end
