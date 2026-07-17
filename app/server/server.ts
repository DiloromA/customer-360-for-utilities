import { createApp, server, analytics } from "@databricks/appkit";
import { geniePlugin } from "./geniePlugin";
import { focusPlugin } from "./focusPlugin";
import { dataModelPlugin } from "./dataModelPlugin";
import { metricsPlugin } from "./metricsPlugin";

await createApp({
  plugins: [server(), analytics(), geniePlugin(), focusPlugin(), dataModelPlugin(), metricsPlugin()],
});
