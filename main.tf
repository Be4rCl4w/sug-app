terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = ">=4.81.0"
    }

    azuread = {
      source = "hashicorp/azuread"
      version = ">=3.5.0"
    }
  }
}

provider "azuread" {}
provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

data "azurerm_subscription" "primary" {}

data "azurerm_log_analytics_workspace" "law" {
  name                = "DefaultWorkspace-0af19ed5-487a-47e1-bc21-11f4ae6bc5a8-NEU"
  resource_group_name = "defaultresourcegroup-neu"
}

resource"azurerm_resource_group" "rg" {
  name      = "Demo-RG1"
  location  = "northeurope"
}

resource "azurerm_application_insights" "appi" {
  name                = "demo-appi"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"
  workspace_id        = data.azurerm_log_analytics_workspace.law.id
}


resource "azuread_application" "github_deploy" {
  display_name = "gh-deploy"
}

resource "azuread_service_principal" "github_deploy" {
  client_id = azuread_application.github_deploy.client_id
}

resource "azurerm_role_assignment" "contributor" {
  scope                            = data.azurerm_subscription.primary.id
  role_definition_name             = "Contributor"
  principal_id                     = azuread_service_principal.github_deploy.object_id
  skip_service_principal_aad_check = true

}

resource "azurerm_virtual_network" "Hub_vnet" {
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  name                = "Hub_demo_vnet"
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_virtual_network" "Spoke_vnet" {
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  name                = "Spoke_demo_vnet"
  address_space       = ["10.20.0.0/16"]
}

locals {
  Hub_subnets = {
    "AzureBastionSubnet"  = "10.0.1.0/27"
    "AppGatewaySubnet"    = "10.0.2.0/26"
  }
}

locals {
  Spoke_subnets = {
    "WebSubnet" = {
      address_prefix = "10.20.0.0/24"
      delegate       = true # delegation
    }
    "AppSubnet" = {
      address_prefix = "10.20.1.0/24"
      delegate       = false # No delegation
    }
    "DataSubnet" = {
      address_prefix = "10.20.3.0/24"
      delegate       = false # No delegation
    }
    "PrivateEndpointSubnet" = {
      address_prefix = "10.20.4.0/24"
      delegate       = false # No delegation
    }
  }
}

resource "azurerm_subnet" "Spoke_vnet_subnets" {
  for_each             = local.Spoke_subnets
  name                 = each.key
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.Spoke_vnet.name
  address_prefixes     = [each.value.address_prefix]

  # Conditionally add delegation block using dynamic
  dynamic "delegation" {
    for_each = each.value.delegate ? [1] : []

    content {
      name = "app-service-delegation"

      service_delegation {
        name    = "Microsoft.Web/serverFarms"
        actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
      }
    }
  }
}

resource "azurerm_subnet" "Hub_vnet_subnets" {
  for_each             = local.Hub_subnets
  name                 = each.key
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.Hub_vnet.name
  address_prefixes     = [each.value]
}

resource "azuread_application_federated_identity_credential" "github_branch" {
  application_id = azuread_application.github_deploy.id
  display_name   = "github-prod-environment"
  description    = "Federated credential for GitHub Actions locked to the production environment."
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:Be4rCl4w@121987346/sug-app@1459678438:ref:refs/heads/main"
}

resource "azurerm_service_plan" "demo_plan" {
  name                = "My-demo-plan"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "P0v3"
}

resource "azurerm_linux_web_app" "webapp" {
  name                = "miWebapp65748"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.demo_plan.id

  site_config {
    always_on                         = true
    minimum_tls_version               = "1.2"
    ftps_state                        = "Disabled"
    http2_enabled                     = true
    health_check_path                 = "/health"
    health_check_eviction_time_in_min = 5

    application_stack {
      node_version = "24-lts"
    }
    # Serve plain HTML files from /home/site/wwwroot on port 8080
    app_command_line = "sh -c \"echo \\\"window.API_BASE_URL='$API_BASE_URL';\\\" > /home/site/wwwroot/config.js && pm2 serve /home/site/wwwroot --no-daemon --spa\""
  }

  https_only                                     = false
  public_network_access_enabled                  = true
  virtual_network_subnet_id                      = azurerm_subnet.Spoke_vnet_subnets["WebSubnet"].id
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false

  identity {
    type = "SystemAssigned"
  }
  app_settings = {
    "SCM_DO_BUILD_DURING_DEPLOYMENT"             = "false"
    "ApplicationInsightsAgent_EXTENSION_VERSION" = "~3"
    "APPLICATIONINSIGHTS_CONNECTION_STRING"      = azurerm_application_insights.appi.connection_string
    "API_BASE_URL"                               = "http://${azurerm_public_ip.lb_public_ip.ip_address}/api"
  }
  

  logs {
    detailed_error_messages = true
    failed_request_tracing  = true

    http_logs {
      file_system {
        retention_in_days = 30
        retention_in_mb   = 100
      }
    }
  }
}

resource "azurerm_public_ip" "lb_public_ip" {
  name                = "my-lb-public-ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "lb" {
  name                = "my-lb"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                          = "private-frontend"
    public_ip_address_id          = azurerm_public_ip.lb_public_ip.id
  }
}

resource "azurerm_lb_backend_address_pool" "pool" {
  name            = "vmss-backend-pool"
  loadbalancer_id = azurerm_lb.lb.id
}

resource "azurerm_lb_probe" "http" {
  name                = "http-probe"
  loadbalancer_id     = azurerm_lb.lb.id
  protocol            = "Http"
  port                = 3000
  request_path        = "/api/health"
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "http" {
  name                           = "http-rule"
  loadbalancer_id                = azurerm_lb.lb.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 3000
  frontend_ip_configuration_name = "private-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.pool.id]
  probe_id                       = azurerm_lb_probe.http.id
}


resource "azurerm_linux_virtual_machine_scale_set" "vmss" {
  name                = "demo-vmss"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Standard_B2s"
  instances           = 1
  admin_username      = "adminuser"
  health_probe_id     = azurerm_lb_probe.http.id

  admin_ssh_key {
    username   = "adminuser"
    public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCtkjuZrrWpBLFtvglHrFk9JJv1sjufeDPSVqIzWHAJfrzMottNf6xaSBU1vVBTNjceLAt2Xe8utrsFUyLw9uJkT6IPhdUt66EOQjZTUPqemQ96UDSjLhmCzSeFG5off/pweLWX1KKafutPnkQHVHdg4bxuqDTtC8cOeXs7vAn/gMp18rUpQ+IMpSo81rneBRt/nisowmI5u9AMQx3U7qdw2rxe3lp19tJcHUPauTtS8mXGISfcIpYO1zUQjag+mwP4aGJZx0MBU0e7HXxF5mc1rmtin4iEHgqXuWhj5uHFOlxiqA9TuBheTHfU1kYr2obaSF+6G/tJsconRuIDC7r524/AeoUWbZYPNN8ckQoaxn2tZ98SY91k/DzF42N78N5nlf5iNXZsJWmwoMTwDmR2fxLAmTaQvyHWwfW+5jaJBez7plsmAzfhAsYNaxPtVfHZd6V/HHYheLGfjyxBB/x+vc1Bk1zxMKmuIRdLxIJX7lUaGtZsQhFWhFxswHARPs3RcU0cFcmqbjQZXukIzjmnFwRHdYHhzVDkD9HYeHtbRBQc3X22YmQwRx/m4ao7sGc5MNV+zVguOXiIifopamYbC3OPZGMjNohZGoc7LdxcVU/K3w+WIFwTRwC2ZNN1RzklMUwcG49iGy7EJutCnAN0GOKwwr4SYViPMGW/UiuFlQ== emerie@Maverick"
  }

  identity {
    type = "SystemAssigned"
  }

  extension {
    name                       = "AADSSHLoginForLinux"
    publisher                  = "Microsoft.Azure.ActiveDirectory"
    type                       = "AADSSHLoginForLinux"
    type_handler_version       = "1.0"
    auto_upgrade_minor_version = true
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  encryption_at_host_enabled = true

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "demo-nic"
    primary = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.Spoke_vnet_subnets["AppSubnet"].id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.pool.id]

    }
  }

 # Read and Base64-encode your cloud-init.yml file
  custom_data = filebase64("${path.module}/cloud-init.yml")

  depends_on = [
    azurerm_lb_rule.http
  ]
}

resource "azurerm_monitor_autoscale_setting" "vmss_autoscale" {
  name                = "myAutoscaleSetting"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.vmss.id

  profile {
    name = "defaultProfile"

    capacity {
      default = 1
      minimum = 1
      maximum = 2
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 75
        metric_namespace   = "microsoft.compute/virtualmachinescalesets"
        dimensions {
          name     = "AppName"
          operator = "Equals"
          values   = ["App1"]
        }
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.vmss.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 25
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }
  }

  predictive {
    scale_mode      = "Enabled"
    look_ahead_time = "PT5M"
  }
}


resource "azurerm_mssql_server" "sql_server" {
  name                          = "demosqlserver0978432"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = "swedencentral"
  version                       = "12.0"
  public_network_access_enabled = false
  minimum_tls_version           = "1.2"


  azuread_administrator {
    login_username              = "SqlAdmin"
    object_id                   = "871c4aff-646b-4834-a694-153db4ced420"
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = true
  }

  identity {
    type = "SystemAssigned"
  }

  outbound_network_restriction_enabled = true

  express_vulnerability_assessment_enabled = true
}


resource "azurerm_mssql_database" "sql_database" {
  name                                = "demo_sql_database7893"
  server_id                           = azurerm_mssql_server.sql_server.id
  collation                           = "SQL_Latin1_General_CP1_CI_AS"
  max_size_gb                         = 5
  sku_name                            = "S0"
  enclave_type                        = "VBS"
  transparent_data_encryption_enabled = true
}

resource "azurerm_mssql_server_extended_auditing_policy" "demo" {
  server_id              = azurerm_mssql_server.sql_server.id
  log_monitoring_enabled = true
}

resource "azurerm_mssql_database_extended_auditing_policy" "demo" {
  database_id            = azurerm_mssql_database.sql_database.id
  log_monitoring_enabled = true
}

resource "azurerm_public_ip" "public_ip" {
  name                = "my-ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_bastion_host" "bastion" {
  name                = "demo_bastion"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"
  tunneling_enabled   = true

  ip_configuration {
    name                 = "demo_bastion_ip_config"
    subnet_id            = azurerm_subnet.Hub_vnet_subnets["AzureBastionSubnet"].id
    public_ip_address_id = azurerm_public_ip.public_ip.id
  }
}

############################################
# Web NSG
############################################
resource "azurerm_network_security_group" "web" {
  name                = "Demo-web-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                         = "web-in-http"
    priority                     = 100
    direction                    = "Inbound"
    access                       = "Allow"
    protocol                     = "Tcp"
    source_port_range            = "*"
    destination_port_ranges       = ["80", "8080"]
    source_address_prefix        = "Internet"
    destination_address_prefixes = azurerm_subnet.Spoke_vnet_subnets["WebSubnet"].address_prefixes
    description                  = "HTTP from App Gateway subnet"
  }

  security_rule {
    name                       = "web-in-deny-all"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    description                = "Explicit deny all inbound"
  }

  security_rule {
    name                         = "web-out-to-app"
    priority                     = 100
    direction                    = "Outbound"
    access                       = "Allow"
    protocol                     = "Tcp"
    source_port_range            = "*"
    destination_port_range       = "3000"
    source_address_prefixes      = azurerm_subnet.Spoke_vnet_subnets["WebSubnet"].address_prefixes
    destination_address_prefixes = azurerm_subnet.Spoke_vnet_subnets["AppSubnet"].address_prefixes
    description                  = "Web to app tier"
  }

  security_rule {
    name                       = "web-out-deny-all"
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    description                = "Explicit deny all outbound"
  }
}

############################################
# App NSG
############################################
resource "azurerm_network_security_group" "app" {
  name                = "Demo-app-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "Allow-HTTP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3000"
    source_address_prefix      = "Internet"
    destination_address_prefixes = azurerm_subnet.Spoke_vnet_subnets["AppSubnet"].address_prefixes
  }

  security_rule {
    name                         = "app-in-from-web"
    priority                     = 200
    direction                    = "Inbound"
    access                       = "Allow"
    protocol                     = "Tcp"
    source_port_range            = "*"
    destination_port_range       = "3000"
    source_address_prefixes      = azurerm_subnet.Spoke_vnet_subnets["WebSubnet"].address_prefixes
    destination_address_prefixes = azurerm_subnet.Spoke_vnet_subnets["AppSubnet"].address_prefixes
    description                  = "Only the web tier can reach the app port"
  }

  security_rule {
    name                         = "app-in-admin-bastion"
    priority                     = 300
    direction                    = "Inbound"
    access                       = "Allow"
    protocol                     = "Tcp"
    source_port_range            = "*"
    destination_port_range       = "22"
    source_address_prefixes      = azurerm_subnet.Hub_vnet_subnets["AzureBastionSubnet"].address_prefixes
    destination_address_prefixes = azurerm_subnet.Spoke_vnet_subnets["AppSubnet"].address_prefixes
    description                  = "Admin access via Bastion only"
  }

  security_rule {
    name                       = "Allow-LB-Probes"
    priority                   = 400
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefixes = azurerm_subnet.Spoke_vnet_subnets["AppSubnet"].address_prefixes
  }

  security_rule {
    name                       = "app-in-deny-all"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    description                = "Explicit deny all inbound"
  }

  security_rule {
    name                         = "app-out-to-db"
    priority                     = 100
    direction                    = "Outbound"
    access                       = "Allow"
    protocol                     = "Tcp"
    source_port_range            = "*"
    destination_port_range       = "1433"
    source_address_prefixes      = azurerm_subnet.Spoke_vnet_subnets["AppSubnet"].address_prefixes
    destination_address_prefixes = azurerm_subnet.Spoke_vnet_subnets["DataSubnet"].address_prefixes
    description                  = "App to database on DB port only"
  }

  security_rule {
    name                         = "app-out-for-AADSSHLoginForLinux-setup"
    priority                     = 400
    direction                    = "Outbound"
    access                       = "Allow"
    protocol                     = "Tcp"
    source_port_range            = "*"
    destination_port_ranges      = ["80", "443"]
    source_address_prefixes      = azurerm_subnet.Spoke_vnet_subnets["AppSubnet"].address_prefixes
    destination_address_prefix   = "Internet"
    description                  = "Allow outbound to internet for AADSSHLoginForLinux setup"
  }

  security_rule {
    name                       = "app-out-deny-all"
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    description                = "Explicit deny all outbound"
  }
}

############################################
# DB NSG
############################################
resource "azurerm_network_security_group" "db" {
  name                = "Demo-db-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                         = "db-in-from-app"
    priority                     = 100
    direction                    = "Inbound"
    access                       = "Allow"
    protocol                     = "Tcp"
    source_port_range            = "*"
    destination_port_range       = "1433"
    source_address_prefixes      = azurerm_subnet.Spoke_vnet_subnets["AppSubnet"].address_prefixes
    destination_address_prefixes = azurerm_subnet.Spoke_vnet_subnets["DataSubnet"].address_prefixes
    description                  = "Only the app tier can reach the DB port"
  }

  security_rule {
    name                       = "db-in-deny-all"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    description                = "Explicit deny all inbound"
  }

  security_rule {
    name                       = "db-out-deny-all"
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    description                = "Explicit deny all outbound"
  }
}

############################################
# Subnet associations
############################################
resource "azurerm_subnet_network_security_group_association" "web" {
  subnet_id                 = azurerm_subnet.Spoke_vnet_subnets["WebSubnet"].id
  network_security_group_id = azurerm_network_security_group.web.id
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.Spoke_vnet_subnets["AppSubnet"].id
  network_security_group_id = azurerm_network_security_group.app.id
}

resource "azurerm_subnet_network_security_group_association" "db" {
  subnet_id                 = azurerm_subnet.Spoke_vnet_subnets["DataSubnet"].id
  network_security_group_id = azurerm_network_security_group.db.id
}

# 1. Create a Public IP for the NAT Gateway
resource "azurerm_public_ip" "nat_gateway_ip" {
  name                = "vmss-nat-gateway-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# 2. Create the NAT Gateway
resource "azurerm_nat_gateway" "nat_gateway" {
  name                    = "vmss-nat-gateway"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
}

# 3. Associate NAT Gateway IP
resource "azurerm_nat_gateway_public_ip_association" "nat_ip_assoc" {
  nat_gateway_id       = azurerm_nat_gateway.nat_gateway.id
  public_ip_address_id = azurerm_public_ip.nat_gateway_ip.id
}

# 4. Associate NAT Gateway with your Subnet
resource "azurerm_subnet_nat_gateway_association" "subnet_nat_ass" {
  subnet_id      = azurerm_subnet.Spoke_vnet_subnets["AppSubnet"].id
  nat_gateway_id = azurerm_nat_gateway.nat_gateway.id
}