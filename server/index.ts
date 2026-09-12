import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import dotenv from "dotenv";
import { sshManager } from "./ssh-manager.js";
import { wait } from "./utils.js";

// Load environment variables
dotenv.config();

// Hyperbolic API base URL.
// The original server targeted /v1/marketplace, which Hyperbolic retired.
// The live API is the v2 "Castle" API: https://api.hyperbolic.xyz/v2/openapi.json
const HYPERBOLIC_API_BASE = "https://api.hyperbolic.xyz/v2";

// Create MCP server instance
const server = new McpServer({
  name: "hyperbolic-gpu-server",
  version: "2.0.0",
});

// Utility function to make authenticated API requests to Hyperbolic
async function makeHyperbolicRequest(
  endpoint: string,
  method: string = "GET",
  body?: any
) {
  const token = process.env.HYPERBOLIC_API_TOKEN;

  if (!token) {
    throw new Error("HYPERBOLIC_API_TOKEN environment variable is not set");
  }

  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${token}`,
  };

  const requestOptions: RequestInit = {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  };

  try {
    const response = await fetch(
      `${HYPERBOLIC_API_BASE}${endpoint}`,
      requestOptions
    );

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(
        `Hyperbolic API error (${response.status}): ${errorText}`
      );
    }

    return await response.json();
  } catch (error) {
    console.error("Error making Hyperbolic API request:", error);
    throw error;
  }
}

const GPU_TYPES = ["h100", "h200", "b200"] as const;

function usd(cents: number | null | undefined): number | null {
  return typeof cents === "number" ? Math.round(cents) / 100 : null;
}

function errorResult(error: unknown) {
  return {
    content: [
      {
        type: "text" as const,
        text: JSON.stringify(
          { status: "error", error: (error as Error).message },
          null,
          2
        ),
      },
    ],
    isError: true,
  };
}

function jsonResult(payload: unknown) {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(payload, null, 2) }],
  };
}

// Shape a v2 rental option for the model
function formatOption(o: any) {
  return {
    gpu_type: o.gpuType,
    gpu_count: o.gpuCount,
    region: o.region,
    machine_type: o.machineType,
    gpu_form_factor: o.gpuFormFactor,
    network: o.connectionType,
    price_per_hour_usd: usd(o.costPerHourCents),
    total_available: o.totalAvailable ?? null,
    node_specs: (o.nodes || []).map((n: any) => ({
      cpu: n.cpuModel,
      vcpus: n.vcpuCount,
      ram_gb: n.ramGb,
      storage_gb: n.storageGb,
      gpus: n.gpuCount,
    })),
  };
}

// Shape a v2 rental record for the model
function formatRental(r: any) {
  const ssh = r.providerData?.sshNetworking || [];
  return {
    rental_id: r.id,
    status: r.status,
    gpu_type: r.gpuType,
    gpu_count: r.gpuCount,
    region: r.region,
    label: r.label ?? r.name ?? null,
    created_at: r.createdAt ?? null,
    started_at: r.startedAt ?? null,
    price_per_hour_usd: usd(r.currentTerm?.costPerHourCents),
    ssh: ssh.map((s: any) => ({
      host: s.host,
      port: s.port,
      user: s.user,
      command: `ssh -p ${s.port} ${s.user}@${s.host}`,
    })),
    public_ips: (r.providerData?.nodeNetworking || []).map(
      (n: any) => n.publicIp
    ),
  };
}

async function fetchVmOptions(): Promise<any[]> {
  const data = await makeHyperbolicRequest("/on-demand/rental-options");
  if (!Array.isArray(data)) {
    throw new Error("Invalid response format from Hyperbolic API");
  }
  return data.filter(
    (o: any) => o.enabled && o.machineType === "virtual-machine"
  );
}

async function fetchVmRentals(): Promise<any[]> {
  const data = await makeHyperbolicRequest("/on-demand/virtual-machine-rentals");
  if (!Array.isArray(data)) {
    throw new Error("Invalid response format from Hyperbolic API");
  }
  return data;
}

// Register tool for listing available GPUs
server.tool(
  "list-available-gpus",
  {
    gpu_type: z
      .enum(GPU_TYPES)
      .optional()
      .describe("Optional filter: h100, h200 or b200"),
  },
  async ({ gpu_type }) => {
    try {
      let options = await fetchVmOptions();
      if (gpu_type) options = options.filter((o: any) => o.gpuType === gpu_type);

      if (options.length === 0) {
        return jsonResult({
          status: "success",
          available_options: [],
          message: "No on-demand virtual machine options are available right now.",
        });
      }

      return jsonResult({
        status: "success",
        available_options: options.map(formatOption),
        total_options: options.length,
        rental_instructions: {
          tool: "rent-gpu-instance",
          required_parameters: ["gpu_type", "region", "gpu_count"],
          note: "gpu_type and region must match one of the options above exactly.",
        },
      });
    } catch (error) {
      return errorResult(error);
    }
  }
);

// Register tool for account balance (read-only)
server.tool("get-account-balance", {}, async () => {
  try {
    const data = await makeHyperbolicRequest("/customer/balance");
    return jsonResult({
      status: "success",
      balance_usd: usd(data.balanceCents),
      max_overdraft_usd: usd(data.maxOverdraftCents),
    });
  } catch (error) {
    return errorResult(error);
  }
});

// Register tool for details of one GPU option
server.tool(
  "get-gpu-option-details",
  {
    gpu_type: z.enum(GPU_TYPES).describe("h100, h200 or b200"),
    region: z.string().describe("Region code exactly as returned by list-available-gpus"),
  },
  async ({ gpu_type, region }) => {
    try {
      const options = await fetchVmOptions();
      const matches = options.filter(
        (o: any) => o.gpuType === gpu_type && o.region === region
      );
      if (matches.length === 0) {
        return {
          content: [
            {
              type: "text",
              text: `No enabled virtual machine option for ${gpu_type} in ${region}. Run list-available-gpus to see current options.`,
            },
          ],
          isError: true,
        };
      }
      return jsonResult({
        status: "success",
        options: matches.map(formatOption),
        rental_instructions: {
          tool: "rent-gpu-instance",
          parameters: { gpu_type, region, gpu_count: matches[0].gpuCount },
        },
      });
    } catch (error) {
      return errorResult(error);
    }
  }
);

// Register tool for renting a GPU instance
server.tool(
  "rent-gpu-instance",
  {
    gpu_type: z.enum(GPU_TYPES).describe("h100, h200 or b200"),
    region: z
      .string()
      .describe("Region code exactly as returned by list-available-gpus (e.g. us-east-1)"),
    gpu_count: z.number().int().min(1).describe("Number of GPUs to rent"),
    label: z.string().optional().describe("Optional label for the rental"),
  },
  async ({ gpu_type, region, gpu_count, label }) => {
    try {
      // Validate against live options so a typo cannot rent the wrong thing
      const options = await fetchVmOptions();
      const option = options.find(
        (o: any) =>
          o.gpuType === gpu_type && o.region === region && o.gpuCount === gpu_count
      );

      if (!option) {
        const alternatives = options
          .filter((o: any) => o.gpuType === gpu_type)
          .map((o: any) => `${o.gpuCount}x ${o.gpuType} in ${o.region} at $${usd(o.costPerHourCents)}/hr`);
        return {
          content: [
            {
              type: "text",
              text:
                `Error: no enabled option for ${gpu_count}x ${gpu_type} in ${region}. ` +
                (alternatives.length
                  ? `Available: ${alternatives.join("; ")}.`
                  : "Run list-available-gpus to see what is available."),
            },
          ],
          isError: true,
        };
      }

      const requestBody: any = {
        gpuType: gpu_type,
        region,
        gpuCount: gpu_count,
        networkType: option.connectionType || "ethernet",
        termType: "on-demand",
      };
      if (label) requestBody.label = label;

      const created = await makeHyperbolicRequest(
        "/on-demand/virtual-machine-rentals",
        "POST",
        requestBody
      );

      // Return immediately. Booting takes minutes and a blocking call risks
      // being timed out or retried by the client, which would rent twice.
      const rental = created;
      return jsonResult({
        status: rental.status === "Running" ? "success" : "pending",
        rental: formatRental(rental),
        price_per_hour_usd: usd(option.costPerHourCents),
        note:
          rental.status === "Running"
            ? "Instance is running. Use ssh-connect with the host, port and user above."
            : `Rental ${rental.id} is ${rental.status ?? "Pending"}. Boot takes a few minutes. Call list-user-instances until status is Running and ssh details appear. Do not call rent-gpu-instance again.`,
      });
    } catch (error) {
      return errorResult(error);
    }
  }
);

// Register tool for terminating a GPU instance
server.tool(
  "terminate-gpu-instance",
  {
    rental_id: z
      .number()
      .int()
      .describe("The numeric rental_id from list-user-instances or rent-gpu-instance"),
    reason: z.string().optional().describe("Optional reason, recorded by Hyperbolic"),
  },
  async ({ rental_id, reason }) => {
    try {
      const rentals = await fetchVmRentals();
      const rental = rentals.find((r: any) => r.id === rental_id);
      if (!rental) {
        return {
          content: [
            {
              type: "text",
              text: `Error: rental ${rental_id} was not found among your active rentals.`,
            },
          ],
          isError: true,
        };
      }

      const body: any = { rentalId: rental_id };
      if (reason) body.reason = reason;
      const data = await makeHyperbolicRequest(
        "/on-demand/virtual-machine-rentals/terminate",
        "POST",
        body
      );

      return jsonResult({
        status: "success",
        rental_id,
        message: data.message || "Terminated",
        terminated: {
          gpu_type: rental.gpuType,
          gpu_count: rental.gpuCount,
          region: rental.region,
          started_at: rental.startedAt ?? rental.createdAt ?? null,
          terminated_at: new Date().toISOString(),
        },
      });
    } catch (error) {
      return errorResult(error);
    }
  }
);

// Register SSH connection tool
server.tool(
  "ssh-connect",
  {
    host: z.string().describe("Hostname or IP address of the remote server. Always query the list-user-instances tool to get the host."),
    username: z.string().describe("SSH username for authentication"),
    password: z
      .string()
      .optional()
      .describe("SSH password for authentication (optional if using key)"),
    private_key_path: z
      .string()
      .optional()
      .describe(
        "Path to private key file (optional, uses SSH_PRIVATE_KEY_PATH from environment if not provided)"
      ),
    port: z
      .number()
      .int()
      .min(1)
      .max(65535)
      .default(22)
      .describe("SSH port number (default: 22)"),
  },
  async ({ host, username, password, private_key_path, port }) => {
    try {
      // console.log(
      //   `Attempting SSH connection to ${host}:${port} as ${username}`
      // );
      const result = await sshManager.connect(
        host,
        username,
        password,
        private_key_path,
        port
      );

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              status: result.startsWith("SSH Connection Error") || result.startsWith("SSH Key Error") ? "error" : "success",
              message: result
            }, null, 2)
          },
        ],
        isError: result.startsWith("SSH Connection Error") || result.startsWith("SSH Key Error"),
      };
    } catch (error) {
      console.error("SSH connection failed with error:", error);
      const errorMessage = error
        ? error instanceof Error
          ? error.message || "Unknown error"
          : String(error)
        : "Unknown error";

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              status: "error",
              error: errorMessage
            }, null, 2)
          },
        ],
        isError: true,
      };
    }
  }
);

// Register SSH command execution tool
server.tool(
  "remote-shell",
  {
    command: z.string().describe("Command to execute on the remote server"),
  },
  async ({ command }) => {
    try {
      if (!sshManager.isConnected()) {
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                status: "error",
                error: "No active SSH connection. Please connect first using the ssh-connect tool."
              }, null, 2)
            },
          ],
          isError: true,
        };
      }

      // console.log(`Executing remote command: ${command}`);
      const result = await sshManager.execute(command);

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              status: result.startsWith("Error:") || result.startsWith("SSH Command Error:") ? "error" : "success",
              command,
              output: result || "(Command executed with no output)"
            }, null, 2)
          },
        ],
        isError: result.startsWith("Error:") || result.startsWith("SSH Command Error:"),
      };
    } catch (error) {
      console.error("SSH command execution error:", error);
      const errorMessage = error
        ? error instanceof Error
          ? error.message || "Unknown error"
          : String(error)
        : "Unknown error";

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              status: "error",
              error: errorMessage
            }, null, 2)
          },
        ],
        isError: true,
      };
    }
  }
);

// Register SSH status tool
server.tool("ssh-status", {}, async () => {
  try {
    const status = sshManager.getConnectionInfo();

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            status: "success",
            connection_status: status
          }, null, 2)
        },
      ],
    };
  } catch (error) {
    console.error("SSH status error:", error);
    const errorMessage = error
      ? error instanceof Error
        ? error.message || "Unknown error"
        : String(error)
      : "Unknown error";

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            status: "error",
            error: errorMessage
          }, null, 2)
        },
      ],
      isError: true,
    };
  }
});

// Register SSH disconnect tool
server.tool("ssh-disconnect", {}, async () => {
  try {
    if (!sshManager.isConnected()) {
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              status: "success",
              message: "No active SSH connection to disconnect."
            }, null, 2)
          },
        ],
      };
    }

    await sshManager.disconnect();

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            status: "success",
            message: "SSH connection closed successfully."
          }, null, 2)
        },
      ],
    };
  } catch (error) {
    console.error("SSH disconnect error:", error);
    const errorMessage = error
      ? error instanceof Error
        ? error.message || "Unknown error"
        : String(error)
      : "Unknown error";

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            status: "error",
            error: errorMessage
          }, null, 2)
        },
      ],
      isError: true,
    };
  }
});

// Register tool for listing user's active rentals
server.tool("list-user-instances", {}, async () => {
  try {
    const rentals = await fetchVmRentals();
    if (rentals.length === 0) {
      return jsonResult({
        status: "success",
        instances: [],
        message: "You don't have any active rentals on Hyperbolic.",
      });
    }
    return jsonResult({
      status: "success",
      instances: rentals.map(formatRental),
      total_instances: rentals.length,
    });
  } catch (error) {
    return errorResult(error);
  }
});

// Start the server
async function main() {
  const transport = new StdioServerTransport();
  console.error("Starting Hyperbolic GPU MCP Server...");
  await server.connect(transport);
  console.error("Hyperbolic GPU MCP Server connected and ready");
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
