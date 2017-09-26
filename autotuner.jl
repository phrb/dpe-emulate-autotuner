addprocs()

import StochasticSearch, JSON

@everywhere begin
    using StochasticSearch

    function create_unique_dir(settings::Dict{Symbol, Any})
        unique_dir = string(tempdir(), "/", Base.Random.uuid4())
        mkpath(unique_dir)

        cp(settings[:source_dir], "$unique_dir/$(settings[:source_dir])")
        return unique_dir
    end

    function generate_configuration_file(configuration::Configuration,
                                         unique_dir::String,
                                         settings::Dict{Symbol, Any})
        static_parameters = """
        # Auto-generated DPE Simulate Configuration

        # Static Parameters
        cycles_max           = 10000
        debug                = 1
        xbar_record          = 1
        num_bits             = 16
        int_bits             = 4
        instrn_width         = 48
        edram_buswidth       = 256
        receive_buffer_depth = 16
        cmesh_c              = 4
        num_bits_tileId      = 32
        flit_width           = 32
        num_node             = 1

        # Parameters
        """

        dependency_parameters = """

        # Dependable Static Parameters
        frac_bits            = num_bits - int_bits
        data_width           = num_bits
        xbdata_width         = data_width
        receive_buffer_width = edram_buswidth / num_bits
        packet_width         = edram_buswidth/data_width
        num_tile             = num_node * num_tile_compute + 2
        """

        parameters = ""

        for parameter in keys(configuration.value)
            if typeof(configuration[parameter]) <: EnumParameter
                parameters = string(parameters, "$parameter = $(configuration[parameter].current.value)\n")
            elseif typeof(configuration[parameter]) <: IntegerParameter
                parameters = string(parameters, "$parameter = $(configuration[parameter].value)\n")
            elseif typeof(configuration[parameter]) <: FloatParameter
                parameters = string(parameters, "$parameter = $(configuration[parameter].value)\n")
            end
        end

        all_parameters     = string(static_parameters, parameters)
        all_parameters     = string(all_parameters, dependency_parameters)

        configuration_file = open("$unique_dir/$(settings[:source_dir])/config.py", "w+")
        write(configuration_file, all_parameters)
        close(configuration_file)
    end

    """
    Runs DPE Simulate with a pre-generated configuration file. Output the
    metrics file to the proper directory.
    """
    function run_simulation(unique_dir::String)
        return true
    end

    function parse_metrics(configuration::Configuration,
                           settings::Dict{Symbol, Any})
        try
            unique_dir = create_unique_dir(settings)
            generate_configuration_file(configuration, unique_dir, settings)
            run_simulation(unique_dir)

            """
            Parse simulation metrics file at:
            /unique_dir/settings[:output_dir]/settings[:application]/settings[:metrics_file]
            
            Then, compound metrics (normalized sum?) into the 'value' variable
            """
            value = Base.Inf
            rm(unique_dir, recursive = true)
            return value
        catch exception
            println(exception)
            rm(unique_dir, recursive = true)
            return Base.Inf
        end
    end
end

function generate_search_space(filename::String)
    json_data         = JSON.parsefile(filename)
    parameter_classes = ["ima", "tile", "node"]
    parameters = Array{Parameter, 1}()

    enum_parameters    = [(p, json_data[c]["enum_parameters"][p]) for c in
                          parameter_classes if haskey(json_data[c],
                                                      "enum_parameters")
                          for p in keys(json_data[c]["enum_parameters"])]

    integer_parameters = [(p, json_data[c]["integer_parameters"][p]) for c in
                          parameter_classes if haskey(json_data[c],
                                                      "integer_parameters")
                          for p in keys(json_data[c]["integer_parameters"])]

    float_parameters   = [(p, json_data[c]["float_parameters"][p]) for c in
                          parameter_classes if haskey(json_data[c],
                                                      "float_parameters")
                          for p in keys(json_data[c]["float_parameters"])]

    for parameter in enum_parameters
        values::Array{Parameter, 1} = [StringParameter(value) for value in
                                       parameter[2]["values"]]

        push!(parameters, EnumParameter(values, parameter[2]["initial_value"] +
                                        1, parameter[1]))
    end

    for parameter in integer_parameters
        if parameter[2]["max"] == "num_bits"
            parameter[2]["max"] = 16
        end
        push!(parameters, IntegerParameter(parameter[2]["min"],
                                           parameter[2]["max"],
                                           parameter[2]["initial_value"],
                                           parameter[1]))
    end

    for parameter in float_parameters
        push!(parameters, FloatParameter(parameter[2]["min"],
                                         parameter[2]["max"],
                                         parameter[2]["initial_value"],
                                         parameter[1]))
    end

    return parameters
end

function main()
    settings      = JSON.parsefile("settings/settings.json",
                                   dicttype = Dict{Symbol, Any})
    configuration = Configuration(generate_search_space("settings/search_space.json"),
                                                        "dpe_emulate_configuration")

    tuning_run = Run(cost                = parse_metrics,
                     cost_arguments      = settings,
                     cost_evaluations    = settings[:cost_evaluations],
                     starting_point      = configuration,
                     stopping_criterion  = elapsed_time_criterion,
                     measurement_method  = sequential_measure_mean!,
                     report_after        = settings[:report_after],
                     reporting_criterion = elapsed_time_reporting_criterion,
                     duration            = settings[:duration],
                     methods             = [[:simulated_annealing 1];
                                            [:randomized_first_improvement 1];])
                                            #[:iterated_local_search 1];
                                            #[:iterative_probabilistic_improvement 1];])

    println("Starting tuning run...")

    @spawn optimize(tuning_run)
    result = take!(tuning_run.channel)

    @printf("Time: %.2f Cost: %.4f (Found by %s)\n",
            result.current_time,
            result.cost_minimum,
            result.technique)

    while !result.is_final
        result = take!(tuning_run.channel)
        @printf("Time: %.2f Cost: %.4f (Found by %s)\n",
                result.current_time,
                result.cost_minimum,
                result.technique)
    end

    println("Done.")
    println("Generating autotuned command...")

    file    = open("$(settings[:final_configuration])", "w+")
    command = join(generate_compile_command(result.minimum, ".", settings), " ")

    write(file, command)
    close(file)

    println("Done.")
end

main()
