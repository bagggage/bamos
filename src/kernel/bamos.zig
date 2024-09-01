// This file is not a part of actual kernel code,
// it is used only to provide kernel overview for documentation.

//! # BamOS Kernel
//! 
//! The kernel is a software module responsible for managing
//! all hardware and resource allocation within the system.
//! 
//! The kernel code is designed to distribute certain related
//! functionality among different subsystems. This allows the code to be scalable.
//! 
//! ## Overview
//! 
//! The main kernel subsystems include:
//! - [**Startup code**](./#bamos.start): The code for booting and initializing the kernel.
//! - [**Boot module**](./#bamos.boot): A module that provides an abstraction
//! for interacting with data provided by the bootloader and the functionality
//! necessary in the early stages of kernel initialization.
//! - [**Virtual memory management module**](./#bamos.vm):
//! This module organizes the management of all device memory,
//! allowing for the dynamic allocation of physical memory pages
//! and mapping them to virtual addresses through page tables.
//! The module also includes various allocators and a general
//! interface for architecture-dependent features.
//! - [**Utilities**](./#bamos.utils): A set of auxiliary components,
//! often various implementations of data structures,
//! such as `utils.SList`, `utils.List`, `utils.BinaryTree`, `utils.Bitmap`, `utils.Heap`, and others.
//! - [**Video module**](./#bamos.video):
//! Contains code for interacting with the framebuffer and rendering text.
//! **Note**: This module is temporary and will be removed after
//! the implementation of a fully-fledged device management and driver system.
//! - [**Architecture module**](./#bamos.arch.x86-64.arch): This module provides the implementation
//! of the interface for architecture-dependent features.
//! - [**Logging**](./#bamos.log): The logging system.