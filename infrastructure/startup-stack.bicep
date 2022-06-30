// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

param domain string = ''
param deployedTag string = 'latest'
param name string = 'startupstack'
param dbName string = 'startupstack'
@secure()
param dbPassword string = ''
param location string = resourceGroup().location
param deploymentSpId string

var addressPrefix = '10.0.0.0/16'
var vnetName = '${name}-vnet-${uniqueString(resourceGroup().name)}'
var uniqueName = '${name}${take(uniqueString(resourceGroup().id), 6)}'
resource vnet 'Microsoft.Network/virtualNetworks@2020-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    enableVmProtection: false
    enableDdosProtection: false
    subnets: [
      {
        name: 'WebApp'
        properties: {
          addressPrefix: '10.0.1.0/24'
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: 'db'
        properties: {
          addressPrefix: '10.0.2.0/27'
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
    ]
  }
}

resource webAppSubnet 'Microsoft.Network/virtualNetworks/subnets@2021-02-01' existing = {
  parent: vnet
  name: 'WebApp'
}
resource dbSubnet 'Microsoft.Network/virtualNetworks/subnets@2020-11-01' existing = {
  parent: vnet
  name: 'db'
}

resource utilsSubnet 'Microsoft.Network/virtualNetworks/subnets@2021-02-01' existing = {
  parent: vnet
  name: 'utils'
}

var dbPrivateDnsZoneName = 'private.postgres.database.azure.com'
resource dbPrivateDnsZone 'Microsoft.Network/privateDnsZones@2018-09-01' = {
  name: dbPrivateDnsZoneName
  location: 'global'
  properties: {}
}

resource virtualNetworkLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2018-09-01' = {
  parent: dbPrivateDnsZone
  name: '${dbPrivateDnsZone.name}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

var containerRegistryName = '${replace(name, '-', '')}${uniqueString(resourceGroup().id)}'
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2020-11-01-preview' = {
  location: location
  name: containerRegistryName
  properties: {
    anonymousPullEnabled: false
    dataEndpointEnabled: false
    encryption: {
      status: 'disabled'
    }
    networkRuleBypassOptions: 'AzureServices'
    policies: {
      quarantinePolicy: {
        status: 'disabled'
      }
      retentionPolicy: {
        days: 7
        status: 'disabled'
      }
      trustPolicy: {
        status: 'disabled'
        type: 'Notary'
      }
    }
    publicNetworkAccess: 'Enabled'
    zoneRedundancy: 'Disabled'
  }
  sku: {
    name: 'Basic'
  }
}

var logAnalyticsWorkspaceName = '${name}-logs-workspace'
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/Workspaces@2020-10-01' = {
  location: location
  name: logAnalyticsWorkspaceName
  properties: {
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    retentionInDays: 30
  }
}

var storageAccountName = take('${replace(name, '-', '')}${uniqueString(resourceGroup().id)}', 24)
resource storageAccount 'Microsoft.Storage/storageAccounts@2021-04-01' = {
  kind: 'StorageV2'
  location: location
  name: storageAccountName
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: true
    allowSharedKeyAccess: true
    encryption: {
      keySource: 'Microsoft.Storage'
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
      ipRules: []
      virtualNetworkRules: []
    }
    supportsHttpsTrafficOnly: true
  }
  sku: {
    name: 'Standard_RAGRS'
  }
}
resource storageAccountBlob 'Microsoft.Storage/storageAccounts/blobServices@2021-04-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    changeFeed: {
      enabled: false
    }
    containerDeleteRetentionPolicy: {
      days: 7
      enabled: true
    }
    cors: {
      corsRules: []
    }
    deleteRetentionPolicy: {
      days: 7
      enabled: true
    }
    isVersioningEnabled: false
    restorePolicy: {
      enabled: false
    }
  }
}

resource assetsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-04-01' = {
  parent: storageAccountBlob
  name: 'assets'
  properties: {
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: false
    publicAccess: 'Blob'
  }
}

resource filesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-04-01' = {
  parent: storageAccountBlob
  name: 'files'
  properties: {
    defaultEncryptionScope: '$account-encryption-key'
    denyEncryptionScopeOverride: false
    publicAccess: 'Blob'
  }
}

resource storageContributorRoleDefinition 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
}

resource storageContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  scope: storageAccount
  name: guid('${uniqueName}-storageContributor')
  properties: {
    principalId: deploymentSpId
    roleDefinitionId: storageContributorRoleDefinition.id
  }
}

resource db 'Microsoft.DBForPostgreSql/flexibleServers@2020-02-14-preview' = {
  location: location
  name: '${name}-db-${uniqueString(resourceGroup().id)}'
  properties: {
    delegatedSubnetArguments: {
      subnetArmResourceId: dbSubnet.id
    }
    administratorLogin: '${replace(name, '-', '_')}_admin'
    administratorLoginPassword: dbPassword
    haEnabled: 'Disabled'
    storageProfile: {
      backupRetentionDays: 7
      storageMB: 32768
    }
    privateDnsZoneArguments: {
      privateDnsZoneArmResourceId: dbPrivateDnsZone.id
    }
    version: '12'
  }
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  dependsOn: [
    dbSubnet
    virtualNetworkLink
  ]
}

resource app_db 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2020-11-05-preview' = {
  parent: db
  name: dbName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

var appServicePlanName = '${name}-asp'
resource appServicePlan 'Microsoft.Web/serverfarms@2020-06-01' = {
  kind: 'linux'
  location: location
  name: appServicePlanName
  properties: {
    hyperV: false
    isSpot: false
    isXenon: false
    maximumElasticWorkerCount: 1
    perSiteScaling: false
    reserved: true
    targetWorkerCount: 0
    targetWorkerSizeId: 0
  }
  sku: {
    capacity: 1
    family: 'S'
    name: 'S1'
    size: 'S1'
    tier: 'Standard'
  }
}

var webAppName = '${uniqueName}-webapp'
var asset_hostname = replace(replace(storageAccount.properties.primaryEndpoints.blob, 'https://', ''), '/', '')
var dockerImageName = '${containerRegistryName}.azurecr.io/${name}:${deployedTag}'
resource webApp 'Microsoft.Web/sites@2020-06-01' = {
  location: location
  name: webAppName
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      alwaysOn: true
      linuxFxVersion: 'DOCKER|${dockerImageName}'
      acrUseManagedIdentityCreds: true
      vnetRouteAllEnabled: true
      appSettings: [
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: '${containerRegistryName}.azurecr.io'
        }
        {
          name: 'DATABASE_URL'
          value: 'postgresql://${db.properties.administratorLogin}:${uriComponent(dbPassword)}@${db.properties.fullyQualifiedDomainName}/${dbName}?sslmode=require'
        }
        {
          name: 'AZURE_STORAGE_ACCOUNT_NAME'
          value: storageAccountName
        }
        {
          name: 'AZURE_STORAGE_ACCESS_KEY'
          value: listKeys(storageAccountName, '2021-04-01').keys[0].value
        }
        {
          name: 'SECRET_KEY_BASE'
          value: 'DEFAULT_SECRET_KEY_BASE'
        }
        {
          name: 'AZURE_STORAGE_CONTAINER'
          value: 'files'
        }
        {
          name: 'WEBSITE_DNS_SERVER'
          value: '168.63.129.16'
        }
        {
          name: 'CDN_HOST'
          value: asset_endpoint.properties.hostName
        }
        {
          name: 'RAILS_LOG_TO_STDOUT'
          value: '1'
        }
      ]
    }
  }
  dependsOn: [
    containerRegistry
    webAppSubnet
  ]
}

resource acrPullRoleDefinition 'Microsoft.Authorization/roleDefinitions@2015-07-01' existing = {
  name: '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
}

resource webAppAcrRoleAssignment 'Microsoft.Authorization/roleAssignments@2020-04-01-preview' = {
  name: guid('${uniqueName}-webAppAcr')
  properties: {
    principalId: webApp.identity.principalId
    roleDefinitionId: acrPullRoleDefinition.id
    principalType: 'ServicePrincipal'
  }
  scope: containerRegistry
}

resource webAppNetworkConfig 'Microsoft.Web/sites/networkConfig@2020-12-01' = {
  parent: webApp
  name: 'virtualNetwork'
  properties: {
    subnetResourceId: webAppSubnet.id
  }
}

var cdnProfileName = '${name}-cdn-profile'
resource cdnProfile 'Microsoft.Cdn/profiles@2020-09-01' = {
  location: 'Global'
  name: cdnProfileName
  properties: {}
  sku: {
    name: 'Standard_Microsoft'
  }
}

resource appCdnEndpoint 'Microsoft.Cdn/profiles/endpoints@2020-09-01' = {
  parent: cdnProfile
  location: 'Global'
  name: '${uniqueName}-app'
  properties: {
    deliveryPolicy: {
      rules: [
        {
          actions: [
            {
              name: 'UrlRedirect'
              parameters: {
                '@odata.type': '#Microsoft.Azure.Cdn.Models.DeliveryRuleUrlRedirectActionParameters'
                destinationProtocol: 'Https'
                redirectType: 'Moved'
              }
            }
          ]
          conditions: [
            {
              name: 'RequestScheme'
              parameters: {
                '@odata.type': '#Microsoft.Azure.Cdn.Models.DeliveryRuleRequestSchemeConditionParameters'
                matchValues: [
                  'HTTP'
                ]
                negateCondition: false
                operator: 'Equal'
              }
            }
          ]
          name: 'ForceSSL'
          order: 1
        }
      ]
    }
    isCompressionEnabled: true
    contentTypesToCompress: [
      'text/plain'
      'text/html'
      'text/css'
      'application/x-javascript'
      'text/javascript'
    ]
    isHttpAllowed: true
    isHttpsAllowed: true
    originHostHeader: webApp.properties.defaultHostName
    origins: [
      {
        name: 'web-origin'
        properties: {
          enabled: true
          hostName: webApp.properties.defaultHostName
          httpPort: 80
          httpsPort: 443
          originHostHeader: webApp.properties.defaultHostName
          priority: 1
          weight: 1000
        }
      }
    ]
    queryStringCachingBehavior: 'IgnoreQueryString'
    urlSigningKeys: []
  }
}

resource asset_endpoint 'Microsoft.Cdn/profiles/endpoints@2020-09-01' = {
  parent: cdnProfile
  location: 'Global'
  name: '${uniqueName}-assets'
  properties: {
    isCompressionEnabled: true
    contentTypesToCompress: [
      'text/plain'
      'text/html'
      'text/css'
      'application/x-javascript'
      'text/javascript'
    ]
    isHttpAllowed: false
    isHttpsAllowed: true
    optimizationType: 'GeneralWebDelivery'
    originGroups: []
    originHostHeader: asset_hostname
    originPath: '/assets'
    origins: [
      {
        name: 'assets-origin'
        properties: {
          enabled: true
          hostName: asset_hostname
          originHostHeader: asset_hostname
          priority: 1
          weight: 1000
        }
      }
    ]
    queryStringCachingBehavior: 'IgnoreQueryString'
    urlSigningKeys: []
  }
}

resource webAppCustomDomain 'Microsoft.Cdn/profiles/endpoints/customdomains@2020-09-01' = if (!empty(domain)) {
  parent: appCdnEndpoint
  name: '${name}-custom-domain'
  properties: {
    hostName: domain
  }
}

output url string = 'https://${appCdnEndpoint.properties.hostName}'
output webAppName string = webAppName
