import json
import os
import subprocess
from collections import defaultdict
import math
import argparse
import csv # Import the csv module

def parse_fio_output(file_path):
  """
  Parses a single FIO JSON output file and extracts relevant metrics along with their units.
  Assumes a single job per FIO run for simplicity.
  Adjust if you have multiple jobs defined within one FIO job file.
  """
  metrics = {}
  units = {}  # Dictionary to store units for each metric

  try:
    with open(file_path, 'r') as f:
      data = json.load(f)
  except FileNotFoundError:
    print(f"Error: File not found at {file_path}")
    return {}, {}
  except json.JSONDecodeError:
    print(f"Error: Invalid JSON in {file_path}")
    return {}, {}

  if 'jobs' in data and len(data['jobs']) > 0:
    # Assuming we're interested in the first job's metrics.
    job_data = data['jobs'][0]

    # --- CPU Usage ---
    metrics['cpu_usr'] = job_data.get('usr_cpu', 0)
    units['cpu_usr'] = '%'
    metrics['cpu_sys'] = job_data.get('sys_cpu', 0)
    units['cpu_sys'] = '%'
    metrics['cpu_total'] = metrics['cpu_usr'] + metrics['cpu_sys']
    units['cpu_total'] = '%'

    # --- Bandwidth (read + write if both exist, otherwise just one) ---
    read_bw = job_data.get('read', {}).get('bw', 0)
    write_bw = job_data.get('write', {}).get('bw', 0)
    # FIO's bw_mean is typically in KiB/s. Convert to MiB/s.
    metrics['bandwidth'] = (read_bw + write_bw) / 1024.0
    units['bandwidth'] = 'MiB/s'

    # --- Latency (checking for different units: ns, us, ms, and converting to ms) ---
    latency_unit = 'ms'
    latency_data = None
    conversion_factor = 1.0  # Default for ms

    # Prioritize nanoseconds (ns), then microseconds (us), then milliseconds (ms)
    # Check read latency first
    if job_data.get('read', {}).get('lat_ns'):
      latency_data = job_data['read']['lat_ns']
      conversion_factor = 1_000_000.0  # ns to ms
    elif job_data.get('read', {}).get('lat_us'):
      latency_data = job_data['read']['lat_us']
      conversion_factor = 1_000.0  # us to ms
    elif job_data.get('read', {}).get('lat_ms'):
      latency_data = job_data['read']['lat_ms']
      conversion_factor = 1.0  # ms to ms (no conversion)
    # If no read latency, check write latency
    elif job_data.get('write', {}).get('lat_ns'):
      latency_data = job_data['write']['lat_ns']
      conversion_factor = 1_000_000.0  # ns to ms
    elif job_data.get('write', {}).get('lat_us'):
      latency_data = job_data['write']['lat_us']
      conversion_factor = 1_000.0  # us to ms
    elif job_data.get('write', {}).get('lat_ms'):
      latency_data = job_data['write']['lat_ms']
      conversion_factor = 1.0  # ms to ms (no conversion)

    if latency_data:
      metrics['avg_latency'] = latency_data.get('mean', 0) / conversion_factor
      units['avg_latency'] = latency_unit
      metrics['stdev_latency'] = latency_data.get('stddev', 0) / conversion_factor
      units['stdev_latency'] = latency_unit  # Stddev has the same unit as mean
    else:
      # If no latency data found, set to 0 and 'N/A' unit
      metrics['avg_latency'] = 0
      units['avg_latency'] = 'N/A'
      metrics['stdev_latency'] = 0
      units['stdev_latency'] = 'N/A'

    # --- IOPS (read + write if both exist, otherwise just one) ---
    read_iops = job_data.get('read', {}).get('iops', 0)
    write_iops = job_data.get('write', {}).get('iops', 0)
    metrics['iops'] = read_iops + write_iops
    units['iops'] = 'ops/s'  # Operations per second

  return metrics, units

def generate_fio_filenames(num_iterations: int, prefix: str) -> list[str]:
  """
  Generates a list of FIO (Flexible I/O Tester) filenames based on a prefix
  and a specified number of iterations.

  Args:
      num_iterations (int): The total number of filenames to generate.
                            Filenames will be numbered from 1 to num_iterations.
      prefix (str): The string prefix for each filename.

  Returns:
      list[str]: A list of strings, where each string is a generated filename
                 in the format "prefix{iteration}.json".

  Examples:
      >>> generate_fio_filenames(3, "test_file_")
      ['test_file_1.json', 'test_file_2.json', 'test_file_3.json']

      >>> generate_fio_filenames(5, "data_")
      ['data_1.json', 'data_2.json', 'data_3.json', 'data_4.json', 'data_5.json']
  """
  if not isinstance(num_iterations, int) or num_iterations <= 0:
    raise ValueError("num_iterations must be a positive integer.")
  if not isinstance(prefix, str) or not prefix:
    raise ValueError("prefix must be a non-empty string.")

  generated_filenames = []
  # Loop from 1 up to and including num_iterations
  for i in range(1, num_iterations + 1):
    filename = f"{prefix}{i}.json"
    generated_filenames.append(filename)

  return generated_filenames

def main():
  """
  Main function to orchestrate FIO job execution and parsing.
  Uses argparse for command-line argument parsing and outputs to CSV.
  """
  # Set up argument parser for command-line options
  parser = argparse.ArgumentParser(
      description="Run FIO benchmarks multiple times and parse the results."
  )
  parser.add_argument(
      "--iterations",
      type=int,
      default=5,  # Default number of iterations
      help="Number of times to run the FIO job"
  )
  parser.add_argument(
      "--output-filepath",
      type=str,
      default="fio-csv",  # Default prefix for output files
      help="Prefix for the FIO output JSON files (e.g., 'fio-output' will result in fio-output1.json, fio-output2.json, etc.)"
  )
  parser.add_argument(
      "--csv-output",
      type=str,
      default="fio_results.csv",  # Default CSV output file name
      help="Name of the CSV file to write the aggregated results to"
  )


  args = parser.parse_args()
  # Corrected attribute access for output-filepath
  generated_fio_files = generate_fio_filenames(args.iterations, args.output_filepath)

  print("\n--- Parsing FIO Output Files ---")
  all_metrics = defaultdict(list)
  global_units_map = {}  # To store units for each metric across all runs

  # Lists to collect latency values for overall min/max
  avg_latency_values = []
  stdev_latency_values = []

  # List to store individual run metrics for CSV output
  individual_run_data = []

  # Iterate through the files that were actually generated
  for i, file_path in enumerate(generated_fio_files):
    print(f"Parsing {file_path}...")
    metrics, units = parse_fio_output(file_path)
    if metrics:
      global_units_map.update(units)  # Update the global units map with units from this file
      print(f"  Results from {os.path.basename(file_path)}:")

      # Prepare data for individual run CSV output
      run_data = {'Run': i + 1}
      for key, value in metrics.items():
        unit = units.get(key, '')
        print(f"    {key}: {value:.2f} {unit}")
        all_metrics[key].append(value)
        run_data[f"{key} ({unit})"] = f"{value:.2f}" # Store with unit for CSV

      individual_run_data.append(run_data)

      # Collect latency values if they are valid
      if 'avg_latency' in metrics and units.get('avg_latency') != 'N/A':
        avg_latency_values.append(metrics['avg_latency'])
      if 'stdev_latency' in metrics and units.get('stdev_latency') != 'N/A':
        stdev_latency_values.append(metrics['stdev_latency'])
    else:
      print(f"  Could not extract metrics from {file_path}. Skipping.")

  if not all_metrics:
    print("No metrics extracted from any FIO output files. Exiting.")
    return

  # --- Prepare Aggregated Results for CSV ---
  aggregated_results = []
  aggregated_results.append(['Metric', 'Average', 'Std Dev', 'Unit', 'Min', 'Max'])

  for metric_name, values in all_metrics.items():
    if values:
      avg_value = sum(values) / len(values)
      unit = global_units_map.get(metric_name, '')
      min_value = min(values)
      max_value = max(values)

      stdev_value = 0
      if len(values) > 1:
        sum_sq_diff = sum([(x - avg_value) ** 2 for x in values])
        stdev_value = math.sqrt(sum_sq_diff / (len(values) - 1))

      aggregated_results.append([
          metric_name.replace('_', ' ').title(),
          f"{avg_value:.2f}",
          f"{stdev_value:.2f}" if len(values) > 1 else "N/A",
          unit,
          f"{min_value:.2f}",
          f"{max_value:.2f}"
      ])
    else:
      aggregated_results.append([metric_name.replace('_', ' ').title(), "No data", "N/A", "N/A", "N/A", "N/A"])

  # Add Min/Max for Average Latency and Standard Deviation of Latency to aggregated results if available
  if avg_latency_values:
    min_avg_latency = min(avg_latency_values)
    max_avg_latency = max(avg_latency_values)
    latency_unit = global_units_map.get('avg_latency', 'ms')
    aggregated_results.append([
        'Average Latency',
        '',
        '',
        latency_unit,
        f"{min_avg_latency:.2f}",
        f"{max_avg_latency:.2f}"
    ])

  if stdev_latency_values:
    min_stdev_latency = min(stdev_latency_values)
    max_stdev_latency = max(stdev_latency_values)
    latency_unit = global_units_map.get('stdev_latency', 'ms')
    aggregated_results.append([
        'Standard Deviation Latency',
        '',
        '',
        latency_unit,
        f"{min_stdev_latency:.2f}",
        f"{max_stdev_latency:.2f}"
    ])


  # --- Write to CSV ---
  try:
    with open(args.csv_output, 'w', newline='') as csvfile:
      writer = csv.writer(csvfile)

      # Write individual run data first
      if individual_run_data:
        # Get all unique keys for the header, maintaining order if possible
        fieldnames = ['Run']
        for row in individual_run_data:
          for key in row.keys():
            if key not in fieldnames:
              fieldnames.append(key)

        writer.writerow(["Individual Run Metrics"])
        writer.writerow(fieldnames)
        for row in individual_run_data:
          writer.writerow([row.get(key, '') for key in fieldnames])
        writer.writerow([]) # Add an empty row for separation

      # Write aggregated results
      writer.writerow(["Aggregated Metrics"])
      for row in aggregated_results:
        writer.writerow(row)
    print(f"\nResults successfully written to {args.csv_output}")
  except IOError as e:
    print(f"Error writing to CSV file {args.csv_output}: {e}")

  print("\nCombined FIO benchmark and parsing script completed.")

if __name__ == "__main__":
  main()