#!/usr/bin/env python3
"""
Wrapper script for Demucs vocal isolation.
This will be compiled into a standalone binary with PyInstaller.

Usage:
    run_demucs --input <audio_file> --output <output_dir> [--model htdemucs] [--two-stems vocals]
"""

import sys
import os
import argparse

def main():
    parser = argparse.ArgumentParser(description='Demucs vocal isolation for Transcriptor')
    parser.add_argument('--input', '-i', required=True, help='Input audio file')
    parser.add_argument('--output', '-o', required=True, help='Output directory')
    parser.add_argument('--model', '-m', default='htdemucs', help='Model to use (default: htdemucs)')
    parser.add_argument('--two-stems', default='vocals', help='Split into two stems (default: vocals)')
    parser.add_argument('--device', '-d', default='mps', help='Device: cpu, cuda, mps (default: mps for Apple Silicon)')
    parser.add_argument('--shifts', type=int, default=1, help='Number of random shifts for prediction (default: 1)')
    parser.add_argument('--overlap', type=float, default=0.25, help='Overlap between segments (default: 0.25)')
    
    args = parser.parse_args()
    
    # Validate input file exists
    if not os.path.exists(args.input):
        print(f"Error: Input file not found: {args.input}", file=sys.stderr)
        sys.exit(1)
    
    # Create output directory if needed
    os.makedirs(args.output, exist_ok=True)
    
    # Import demucs here (after argument parsing for faster --help)
    try:
        import torch
        import torchaudio
        from demucs.pretrained import get_model
        from demucs.apply import apply_model
        from demucs.audio import save_audio
        
        print(f"🎵 Demucs vocal isolation")
        print(f"   Input: {args.input}")
        print(f"   Output: {args.output}")
        print(f"   Model: {args.model}")
        print(f"   Device: {args.device}")
        
        # Select device
        if args.device == 'mps' and torch.backends.mps.is_available():
            device = torch.device('mps')
            print("   Using Apple Silicon GPU (MPS)")
        elif args.device == 'cuda' and torch.cuda.is_available():
            device = torch.device('cuda')
            print("   Using NVIDIA GPU (CUDA)")
        else:
            device = torch.device('cpu')
            print("   Using CPU")
        
        # Load model
        print("   Loading model...")
        model = get_model(args.model)
        model.to(device)
        model.eval()
        
        # Load audio
        print("   Loading audio...")
        wav, sr = torchaudio.load(args.input)
        
        # Resample if needed (demucs expects 44100 Hz)
        if sr != model.samplerate:
            print(f"   Resampling from {sr} Hz to {model.samplerate} Hz...")
            resampler = torchaudio.transforms.Resample(sr, model.samplerate)
            wav = resampler(wav)
            sr = model.samplerate
        
        # Add batch dimension
        wav = wav.unsqueeze(0).to(device)
        
        # Apply model
        print("   Processing (this may take a while)...")
        with torch.no_grad():
            sources = apply_model(
                model, 
                wav, 
                shifts=args.shifts,
                overlap=args.overlap,
                progress=True
            )
        
        # Get source names from model
        source_names = model.sources
        
        # Find vocals index
        vocals_idx = source_names.index('vocals') if 'vocals' in source_names else 0
        
        # Extract vocals
        vocals = sources[0, vocals_idx]
        
        # Get input filename without extension
        input_name = os.path.splitext(os.path.basename(args.input))[0]
        
        # Save vocals
        output_path = os.path.join(args.output, f"{input_name}_vocals.wav")
        print(f"   Saving vocals to: {output_path}")
        
        # Move to CPU for saving
        vocals_cpu = vocals.cpu()
        save_audio(vocals_cpu, output_path, model.samplerate)
        
        print(f"✅ Done! Vocals saved to: {output_path}")
        
    except ImportError as e:
        print(f"Error: Missing dependency - {e}", file=sys.stderr)
        print("Make sure demucs and its dependencies are installed.", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
