/**
  * # Flux (v1)
  *
  * This module is used to add [`flux`](https://github.com/fluxcd/flux) to Kubernetes clusters.
  *
  * ## Details
  *
  * The helm chart is added to this module to add the securityContext parameters to the pod running flux, to make sure it works with the `opa-gatekeeper` module.
  *
  * This module will create a flux instance in each namespace, and not used for fleet-wide configuration.
  *
  * Will be deprecated as soon as Flux v2 module is finished and tested.
  */

terraform {
  required_version = "0.13.5"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "3.0.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "1.13.3"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "1.3.2"
    }
  }
}

resource "random_password" "azdo_proxy" {
  for_each = {
    for ns in var.namespaces :
    ns.name => ns
  }

  length  = 48
  special = false

  keepers = {
    namespace = each.key
  }
}

locals {
  azdo_proxy_json = {
    domain       = var.azure_devops_domain
    pat          = var.azure_devops_pat
    organization = var.azure_devops_org
    repositories = [
      for ns in var.namespaces : {
        project = ns.flux.azure_devops.proj
        name    = ns.flux.azure_devops.repo
        token   = random_password.azdo_proxy[ns.name].result
      }
    ]
  }
}

resource "kubernetes_namespace" "azdo_proxy" {
  metadata {
    labels = {
      name = "azdo-proxy"
    }
    name = "azdo-proxy"
  }
}

resource "kubernetes_secret" "azdo_proxy" {
  metadata {
    name      = "azdo-proxy-config"
    namespace = kubernetes_namespace.azdo_proxy.metadata[0].name
  }

  data = {
    "config.json" = jsonencode(local.azdo_proxy_json)
  }
}

resource "helm_release" "azdo_proxy" {
  repository = "https://xenitab.github.io/azdo-proxy/"
  chart      = "azdo-proxy"
  version    = "v0.3.0"
  name       = kubernetes_namespace.azdo_proxy.metadata[0].name
  namespace  = kubernetes_namespace.azdo_proxy.metadata[0].name

  set {
    name  = "configSecretName"
    value = kubernetes_secret.azdo_proxy.metadata[0].name
  }
}

resource "helm_release" "fluxcd" {
  for_each = {
    for ns in var.namespaces :
    ns.name => ns
    if ns.flux.enabled
  }

  name      = "fluxcd"
  chart     = "${path.module}/charts/flux"
  namespace = each.key

  values = [templatefile("${path.module}/templates/fluxcd-values.yaml.tpl", { namespace = each.key, git_url = "https://dev.azure.com/${each.value.flux.azure_devops.org}/${each.value.flux.azure_devops.proj}/_git/${each.value.flux.azure_devops.repo}", environment = var.environment })]

  set_sensitive {
    name  = "git.config.data"
    value = <<EOF
      [url "http://${random_password.azdo_proxy[each.key].result}@azdo-proxy.azdo-proxy"]
        insteadOf = https://dev.azure.com
      EOF
  }
}

resource "helm_release" "helm_operator" {
  for_each = {
    for ns in var.namespaces :
    ns.name => ns
  }

  repository = "https://charts.fluxcd.io"
  chart      = "helm-operator"
  version    = "1.2.0"
  name       = "helm-operator"
  namespace  = each.key

  values = [templatefile("${path.module}/templates/helm-operator-values.yaml.tpl", { namespace = each.key })]

  set_sensitive {
    name  = "git.config.data"
    value = <<EOF
      [url "http://${random_password.azdo_proxy[each.key].result}@azdo-proxy.azdo-proxy"]
        insteadOf = https://dev.azure.com
      EOF
  }
}
