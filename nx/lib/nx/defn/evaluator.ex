defmodule Nx.Defn.Evaluator do
  @moduledoc """
  The default implementation of a `Nx.Defn.Compiler`
  that evaluates the expression tree against the
  tensor backend.
  """

  @behaviour Nx.Defn.Compiler
  alias Nx.Defn.{Composite, Expr, Tree}

  @creation_ops [:constant, :eye, :iota, :from_binary]
  @random_ops [:random_uniform, :random_normal]

  @impl true
  def __stream__(key, input, acc, vars, fun, opts) do
    count = Nx.Defn.Composite.count(input) + Nx.Defn.Composite.count(acc)
    vars = Enum.drop(vars, count)

    Nx.Defn.Stream.start_link(input, acc, fn input, acc ->
      vars = Nx.Defn.Composite.from_runtime_args([input, acc], vars)
      __jit__(key, vars, fun, opts)
    end)
  end

  @impl true
  def __jit__(_key, vars, fun, opts) do
    hooks = Keyword.get(opts, :hooks, %{})

    fun.(vars)
    |> composite_eval(%{vars: vars, hooks: hooks}, %{})
    |> elem(0)
  end

  defp eval(%Nx.Tensor{data: %Expr{op: :parameter, args: [i]}}, state, cache) do
    {Enum.fetch!(state.vars, i), cache}
  end

  defp eval(%Nx.Tensor{data: %Expr{op: :tensor, args: [t]}}, _state, cache) do
    {t, cache}
  end

  defp eval(%Nx.Tensor{data: %Expr{op: :elem, args: args}}, state, cache) do
    [tuple, i] = args
    {tuple, cache} = composite_eval(tuple, state, cache)
    {elem(tuple, i), cache}
  end

  defp eval(%Nx.Tensor{data: %Expr{op: :attach_token, args: [token, expr]}}, state, cache) do
    {_, cache} = eval(token, state, cache)
    eval(expr, state, cache)
  end

  defp eval(%Nx.Tensor{data: %Expr{op: :metadata, args: [expr, _meta]}}, state, cache) do
    eval(expr, state, cache)
  end

  defp eval(%Nx.Tensor{data: %Expr{op: op, id: id}} = ans, state, cache) do
    case cache do
      %{^id => res} ->
        {res, cache}

      %{} ->
        {res, cache} = eval_apply(op, ans, state, cache)
        {res, Map.put(cache, id, res)}
    end
  end

  defp eval(other, _state, cache) do
    {other, cache}
  end

  defp eval_apply(:fun, %{data: %Expr{args: [args, expr, _mfa]}}, state, cache) do
    fun =
      case length(args) do
        1 ->
          fn arg1 ->
            vars = [Nx.to_tensor(arg1)]
            {result, _cache} = composite_eval(expr, %{state | vars: vars}, %{})
            result
          end

        2 ->
          fn arg1, arg2 ->
            vars = [Nx.to_tensor(arg1), Nx.to_tensor(arg2)]
            {result, _cache} = composite_eval(expr, %{state | vars: vars}, %{})
            result
          end
      end

    {fun, cache}
  end

  defp eval_apply(:cond, %{data: %Expr{args: [clauses, last]}}, state, cache) do
    {res, cache} = cond_clause(clauses, last, state, cache)
    composite_eval(res, state, cache)
  end

  defp eval_apply(:while, %{data: %Expr{args: args}}, state, cache) do
    [initial, _arg, condition, block] = args
    {initial, cache} = composite_eval(initial, state, cache)
    {while(initial, condition, block, state, cache), cache}
  end

  defp eval_apply(:token, %{data: %Expr{args: [token]}}, state, cache) do
    hooks = state.hooks

    cache =
      List.foldr(token.hooks, cache, fn %{callback: callback, expr: expr, name: name}, cache ->
        hook_fun = hooks[name] || callback

        cond do
          hook_fun ->
            {expr, cache} = eval(expr, state, cache)
            hook_fun.(expr)
            cache

          Tree.has_hooks?(expr, hooks) ->
            {_expr, cache} = eval(expr, state, cache)
            cache

          true ->
            cache
        end
      end)

    {{}, cache}
  end

  defp eval_apply(op, ans, state, cache) do
    {args, cache} = Tree.apply_args(ans, cache, &eval(&1, state, &2))

    {mod, args} =
      cond do
        op in @creation_ops ->
          {backend, backend_options} = Nx.default_backend()
          {backend, [ans | args] ++ [backend_options]}

        op in @random_ops ->
          {_, backend_options} = Nx.default_backend()
          {Nx.Shared.list_impl!(args), [ans | args] ++ [backend_options]}

        match?({:tuple, _}, ans.type) ->
          {Nx.Shared.list_impl!(args), args}

        true ->
          {Nx.Shared.list_impl!(args), [ans | args]}
      end

    {apply(mod, op, args), cache}
  end

  defp while(acc, condition, block, state, cache) do
    state = %{state | vars: composite_to_vars(acc)}
    {pred, temp} = eval(condition, state, cache)

    if Nx.to_number(pred) != 0 do
      {acc, _} = composite_eval(block, state, temp)
      while(acc, condition, block, state, cache)
    else
      acc
    end
  end

  defp composite_eval(composite, state, cache) do
    Composite.traverse(composite, cache, &eval(&1, state, &2))
  end

  defp composite_to_vars(composite) do
    composite |> composite_to_vars([]) |> Enum.reverse()
  end

  defp composite_to_vars(tuple, acc) when is_tuple(tuple) do
    Enum.reduce(Tuple.to_list(tuple), acc, &composite_to_vars/2)
  end

  defp composite_to_vars(other, acc) do
    [other | acc]
  end

  defp cond_clause([{pred, clause} | clauses], last, state, cache) do
    {pred, cache} = eval(pred, state, cache)

    if Nx.to_number(pred) != 0,
      do: {clause, cache},
      else: cond_clause(clauses, last, state, cache)
  end

  defp cond_clause([], last, _state, cache) do
    {last, cache}
  end
end
