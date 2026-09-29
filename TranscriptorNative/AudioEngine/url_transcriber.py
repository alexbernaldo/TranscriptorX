#!/usr/bin/env python3
"""
URL Transcriber - Módulo de extracción de transcripciones
Arquitectura:
  - Módulo 1: Orquestador (dispatcher)
  - Módulo 2: Extractor YouTube (youtube-transcript-api)
  - Módulo 3: Descargador Universal (yt-dlp + ffmpeg)
"""

import sys
import json
import re
import html
import tempfile
import os
from urllib.parse import urlparse, parse_qs
from typing import Optional, Dict, Any, List, Tuple

# ============================================================================
# MÓDULO 1: EL ORQUESTADOR (The Dispatcher)
# ============================================================================

class URLDispatcher:
    """Gestiona el tráfico de entrada y clasifica URLs"""
    
    # Patrones para identificar plataformas
    YOUTUBE_PATTERNS = [
        r'(?:https?://)?(?:www\.)?youtube\.com/watch\?v=([a-zA-Z0-9_-]{11})',
        r'(?:https?://)?(?:www\.)?youtube\.com/embed/([a-zA-Z0-9_-]{11})',
        r'(?:https?://)?(?:www\.)?youtube\.com/v/([a-zA-Z0-9_-]{11})',
        r'(?:https?://)?(?:www\.)?youtube\.com/shorts/([a-zA-Z0-9_-]{11})',
        r'(?:https?://)?youtu\.be/([a-zA-Z0-9_-]{11})',
        r'(?:https?://)?(?:www\.)?youtube-nocookie\.com/embed/([a-zA-Z0-9_-]{11})',
        r'(?:https?://)?m\.youtube\.com/watch\?v=([a-zA-Z0-9_-]{11})',
    ]
    
    @staticmethod
    def validate_url(url: str) -> bool:
        """Valida que el string tenga estructura de URL"""
        try:
            result = urlparse(url)
            return all([result.scheme in ('http', 'https'), result.netloc])
        except:
            return False
    
    @staticmethod
    def clean_url(url: str) -> str:
        """Limpia parámetros de tracking innecesarios"""
        parsed = urlparse(url)
        # Mantener solo parámetros esenciales
        essential_params = ['v', 't', 'start', 'end']
        query_params = parse_qs(parsed.query)
        cleaned_params = {k: v[0] for k, v in query_params.items() if k in essential_params}
        
        # Reconstruir URL limpia
        from urllib.parse import urlencode
        clean_query = urlencode(cleaned_params) if cleaned_params else ''
        return f"{parsed.scheme}://{parsed.netloc}{parsed.path}" + (f"?{clean_query}" if clean_query else "")
    
    @classmethod
    def extract_youtube_id(cls, url: str) -> Optional[str]:
        """Extrae el video ID de una URL de YouTube"""
        for pattern in cls.YOUTUBE_PATTERNS:
            match = re.search(pattern, url)
            if match:
                return match.group(1)
        
        # Fallback: buscar en query params
        parsed = urlparse(url)
        query_params = parse_qs(parsed.query)
        if 'v' in query_params:
            video_id = query_params['v'][0]
            if len(video_id) == 11:
                return video_id
        
        return None
    
    @classmethod
    def identify_platform(cls, url: str) -> Tuple[str, Optional[str]]:
        """
        Identifica la plataforma y extrae ID si es posible
        Returns: (platform_name, video_id or None)
        """
        if not cls.validate_url(url):
            return ('invalid', None)
        
        parsed = urlparse(url)
        domain = parsed.netloc.lower()
        
        # YouTube
        youtube_domains = ['youtube.com', 'www.youtube.com', 'm.youtube.com', 
                          'youtu.be', 'youtube-nocookie.com']
        if any(yt in domain for yt in youtube_domains):
            video_id = cls.extract_youtube_id(url)
            return ('youtube', video_id)
        
        # TikTok
        if 'tiktok.com' in domain:
            return ('tiktok', None)
        
        # Instagram
        if 'instagram.com' in domain:
            return ('instagram', None)
        
        # Vimeo
        if 'vimeo.com' in domain:
            return ('vimeo', None)
        
        # Twitter/X
        if 'twitter.com' in domain or 'x.com' in domain:
            return ('twitter', None)
        
        # Otros
        return ('other', None)


# ============================================================================
# MÓDULO 2: EXTRACTOR DE METADATOS (Solo YouTube)
# ============================================================================

class YouTubeExtractor:
    """Extrae transcripciones de YouTube usando youtube-transcript-api"""
    
    # Prioridad de idiomas
    LANGUAGE_PRIORITY = ['es', 'es-ES', 'es-419', 'es-MX', 'en', 'en-US', 'en-GB']
    
    @staticmethod
    def _clean_text(text: str) -> str:
        """Limpia entidades HTML y normaliza texto"""
        # Decodificar entidades HTML
        text = html.unescape(text)
        # Limpiar saltos de línea extra
        text = text.replace('\n', ' ').replace('\r', '')
        # Normalizar espacios
        text = re.sub(r'\s+', ' ', text)
        return text.strip()
    
    @staticmethod
    def _format_paragraphs(segments: List[Dict]) -> str:
        """Convierte segmentos en párrafos legibles"""
        if not segments:
            return ""
        
        paragraphs = []
        current_paragraph = []
        sentence_count = 0
        
        for segment in segments:
            text = YouTubeExtractor._clean_text(segment.get('text', ''))
            if not text:
                continue
            
            current_paragraph.append(text)
            
            # Contar finales de oración
            sentence_endings = len(re.findall(r'[.!?]', text))
            sentence_count += sentence_endings
            
            # Nuevo párrafo cada ~5 oraciones
            if sentence_count >= 5:
                paragraph = ' '.join(current_paragraph)
                paragraphs.append(paragraph)
                current_paragraph = []
                sentence_count = 0
        
        # No olvidar el último párrafo
        if current_paragraph:
            paragraphs.append(' '.join(current_paragraph))
        
        return '\n\n'.join(paragraphs)
    
    @classmethod
    def get_transcript(cls, video_id: str) -> Dict[str, Any]:
        """
        Obtiene la transcripción de un video de YouTube
        Returns: {success: bool, text: str, language: str, is_auto: bool, error: str}
        """
        import sys as _sys
        def debug(msg):
            print(f"[DEBUG get_transcript] {msg}", file=_sys.stderr)
        
        debug(f"Starting get_transcript for video_id: {video_id}")
        
        try:
            from youtube_transcript_api import YouTubeTranscriptApi
            debug("Successfully imported YouTubeTranscriptApi")
            
            # Create API instance (new API style)
            api = YouTubeTranscriptApi()
            debug("Created API instance")
            
            # Try to fetch transcript with language priority
            # First try Spanish, then English
            language_priority = ['es', 'es-ES', 'es-419', 'es-MX', 'en', 'en-US', 'en-GB']
            
            transcript_data = None
            selected_lang = None
            is_auto = False
            
            # Try each language in priority order
            for lang in language_priority:
                try:
                    debug(f"Trying language: {lang}")
                    transcript_data = api.fetch(video_id, languages=[lang])
                    selected_lang = lang
                    debug(f"Success with language: {lang}")
                    break
                except Exception as e:
                    debug(f"Failed for {lang}: {type(e).__name__}: {e}")
                    continue
            
            # If no preferred language found, try to get any available
            if transcript_data is None:
                debug("No preferred language found, trying to list all available transcripts")
                try:
                    # Get list of available transcripts
                    transcript_list = api.list(video_id)
                    debug(f"Found {len(list(transcript_list))} transcripts available")
                    
                    # Re-fetch list since we consumed the iterator
                    transcript_list = api.list(video_id)
                    
                    # Try to find manually created first
                    for transcript in transcript_list:
                        debug(f"Checking transcript: {transcript.language_code}, is_generated={transcript.is_generated}")
                        if not transcript.is_generated:
                            debug(f"Fetching manual transcript: {transcript.language_code}")
                            transcript_data = transcript.fetch()
                            selected_lang = transcript.language_code
                            is_auto = False
                            break
                    
                    # If no manual, get auto-generated
                    if transcript_data is None:
                        debug("No manual transcript, trying auto-generated")
                        transcript_list = api.list(video_id)
                        for transcript in transcript_list:
                            debug(f"Fetching auto transcript: {transcript.language_code}")
                            transcript_data = transcript.fetch()
                            selected_lang = transcript.language_code
                            is_auto = transcript.is_generated
                            break
                            
                except Exception as e:
                    debug(f"Error listing transcripts: {type(e).__name__}: {e}")
                    return {
                        'success': False,
                        'error': 'no_transcript_available',
                        'message': f'No hay transcripción disponible: {str(e)}'
                    }
            
            if transcript_data is None:
                debug("transcript_data is still None after all attempts")
                return {
                    'success': False,
                    'error': 'no_transcript_available',
                    'message': 'No hay transcripción disponible para este video'
                }
            
            debug(f"Processing transcript_data with {len(list(transcript_data)) if hasattr(transcript_data, '__iter__') else 'unknown'} items")
            
            # Convert transcript data to list of dicts if needed
            segments = []
            for item in transcript_data:
                if hasattr(item, 'text'):
                    segments.append({'text': item.text})
                elif isinstance(item, dict):
                    segments.append(item)
            
            debug(f"Extracted {len(segments)} segments")
            
            # Format as readable text
            formatted_text = cls._format_paragraphs(segments)
            debug(f"Formatted text length: {len(formatted_text)} chars, words: {len(formatted_text.split()) if formatted_text else 0}")
            
            if not formatted_text:
                debug("Formatted text is empty!")
                return {
                    'success': False,
                    'error': 'empty_transcript',
                    'message': 'La transcripción está vacía'
                }
            
            return {
                'success': True,
                'text': formatted_text,
                'language': selected_lang,
                'is_auto_generated': is_auto,
                'word_count': len(formatted_text.split())
            }
            
        except Exception as e:
            error_type = type(e).__name__
            
            if 'TranscriptsDisabled' in str(type(e)):
                return {
                    'success': False,
                    'error': 'transcripts_disabled',
                    'message': 'Las transcripciones están deshabilitadas para este video'
                }
            elif 'NoTranscriptFound' in str(type(e)):
                return {
                    'success': False,
                    'error': 'no_transcript_found',
                    'message': 'No se encontró transcripción para este video'
                }
            else:
                return {
                    'success': False,
                    'error': 'extraction_failed',
                    'message': str(e)
                }


# ============================================================================
# MÓDULO 3: DESCARGADOR UNIVERSAL (yt-dlp wrapper)
# ============================================================================

class UniversalDownloader:
    """Descarga audio de cualquier plataforma usando yt-dlp"""
    
    @staticmethod
    def download_audio(url: str, output_dir: str) -> Dict[str, Any]:
        """
        Descarga el audio de una URL
        Returns: {success: bool, audio_path: str, error: str}
        """
        try:
            import yt_dlp
            
            output_template = os.path.join(output_dir, 'audio.%(ext)s')
            
            ydl_opts = {
                'format': 'bestaudio/best',
                'postprocessors': [{
                    'key': 'FFmpegExtractAudio',
                    'preferredcodec': 'm4a',
                    'preferredquality': '192',
                }],
                'outtmpl': output_template,
                'quiet': True,
                'no_warnings': True,
                'extract_flat': False,
                'noplaylist': True,
            }
            
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                ydl.download([url])
            
            # Buscar el archivo descargado
            for file in os.listdir(output_dir):
                if file.startswith('audio.'):
                    return {
                        'success': True,
                        'audio_path': os.path.join(output_dir, file)
                    }
            
            return {
                'success': False,
                'error': 'download_failed',
                'message': 'No se encontró el archivo de audio descargado'
            }
            
        except Exception as e:
            return {
                'success': False,
                'error': 'download_failed',
                'message': str(e)
            }


# ============================================================================
# PUNTO DE ENTRADA PRINCIPAL
# ============================================================================

def process_url(url: str, mode: str = 'auto') -> Dict[str, Any]:
    """
    Procesa una URL y devuelve el resultado
    
    Args:
        url: La URL a procesar
        mode: 'transcript' (solo subtítulos), 'download' (descargar audio), 'auto' (inteligente)
    
    Returns:
        Dict con el resultado
    """
    import sys as _sys
    def debug(msg):
        print(f"[DEBUG process_url] {msg}", file=_sys.stderr)
    
    debug(f"Starting process_url for: {url}")
    
    # Paso 1: Validar y clasificar URL
    dispatcher = URLDispatcher()
    
    if not dispatcher.validate_url(url):
        debug("URL validation failed")
        return {
            'success': False,
            'error': 'invalid_url',
            'message': 'La URL no es válida'
        }
    
    platform, video_id = dispatcher.identify_platform(url)
    clean_url = dispatcher.clean_url(url)
    
    debug(f"Platform: {platform}, Video ID: {video_id}")
    debug(f"Clean URL: {clean_url}")
    
    result = {
        'platform': platform,
        'original_url': url,
        'clean_url': clean_url,
        'video_id': video_id
    }
    
    # Paso 2: Procesar según plataforma
    if platform == 'youtube' and video_id:
        debug(f"Processing YouTube video: {video_id}")
        # Intentar obtener transcripción directa
        if mode in ('auto', 'transcript'):
            debug(f"Calling YouTubeExtractor.get_transcript({video_id})")
            transcript_result = YouTubeExtractor.get_transcript(video_id)
            debug(f"Transcript result: success={transcript_result.get('success')}, error={transcript_result.get('error')}, word_count={transcript_result.get('word_count', 0)}")
            
            if transcript_result['success']:
                result.update(transcript_result)
                result['method'] = 'youtube_transcript_api'
                debug(f"Returning success with {result.get('word_count', 0)} words")
                return result
            
            # Si falla y modo es transcript, devolver error
            if mode == 'transcript':
                debug(f"Mode is transcript, returning error: {transcript_result.get('error')}")
                result.update(transcript_result)
                return result
        
        # Fallback a descarga de audio
        if mode in ('auto', 'download'):
            debug("Falling back to yt-dlp download")
            result['needs_whisper'] = True
            result['method'] = 'yt-dlp'
            
            # Crear directorio temporal
            with tempfile.TemporaryDirectory() as temp_dir:
                download_result = UniversalDownloader.download_audio(clean_url, temp_dir)
                
                if download_result['success']:
                    result['success'] = True
                    result['audio_path'] = download_result['audio_path']
                    # Nota: El archivo se borrará cuando salga del with
                    # En producción, mover a ubicación permanente
                else:
                    result.update(download_result)
            
            return result
    
    elif platform in ('tiktok', 'instagram', 'vimeo', 'twitter', 'other'):
        # Estas plataformas requieren descarga
        result['needs_whisper'] = True
        result['method'] = 'yt-dlp'
        
        with tempfile.TemporaryDirectory() as temp_dir:
            download_result = UniversalDownloader.download_audio(clean_url, temp_dir)
            result.update(download_result)
        
        return result
    
    else:
        return {
            'success': False,
            'error': 'unsupported_platform',
            'message': f'Plataforma no soportada: {platform}'
        }


def main():
    """Punto de entrada CLI"""
    import sys as _sys
    
    # Debug logging to stderr
    def debug(msg):
        print(f"[DEBUG] {msg}", file=_sys.stderr)
    
    debug(f"Script started with args: {sys.argv}")
    
    if len(sys.argv) < 2:
        print(json.dumps({
            'success': False,
            'error': 'missing_url',
            'message': 'Uso: python url_transcriber.py <url> [mode]'
        }))
        sys.exit(1)
    
    url = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else 'auto'
    
    debug(f"URL: {url}")
    debug(f"Mode: {mode}")
    
    result = process_url(url, mode)
    
    debug(f"Result success: {result.get('success')}")
    debug(f"Result word_count: {result.get('word_count', 0)}")
    debug(f"Result text length: {len(result.get('text', '') or '')}")
    
    print(json.dumps(result, ensure_ascii=False, indent=2))
    
    sys.exit(0 if result.get('success') else 1)


if __name__ == '__main__':
    main()
