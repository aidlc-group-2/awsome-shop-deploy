#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { StagingStack } from "../lib/staging-stack";

const app = new cdk.App();

new StagingStack(app, "AwsomeshopStaging", {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT ?? "984072314535",
    region: "us-east-1",
  },
  description:
    "AWSomeShop staging EC2 (rebuildable; SSM-only, zero inbound, CD self-contained)",
});
